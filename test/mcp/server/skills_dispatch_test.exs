defmodule MCP.Server.SkillsDispatchTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MCP.Protocol.Messages.Request
  alias MCP.Server.{Config, Dispatch, LegacyDispatch, ToolContext}

  @extension "io.modelcontextprotocol/skills"
  @version "2026-07-28"

  defmodule Handler do
    @behaviour MCP.Server.Handler

    def init(opts), do: {:ok, opts}

    def handle_list_skills(cursor, ctx, state) do
      send(state[:test_pid], {:list_skills, cursor, ctx.identity})
      {:ok, [state[:skill]], state[:next_cursor]}
    end

    def handle_get_skill(uri, ctx, state) do
      send(state[:test_pid], {:get_skill, uri, ctx.identity})
      {:ok, state[:skill]}
    end

    def handle_read_resource_directory(uri, cursor, ctx, state) do
      send(state[:test_pid], {:read_directory, uri, cursor, ctx.identity})

      {:ok,
       [
         %{
           "uri" => "skill://acme/demo/reference.md",
           "name" => "reference.md",
           "mimeType" => "text/markdown"
         }
       ], nil}
    end

    def handle_read_resource(uri, _ctx, _state), do: {:ok, [%{"uri" => uri, "text" => "ok"}]}
  end

  defmodule SlowHandler do
    @behaviour MCP.Server.Handler

    def init(opts), do: {:ok, opts}
    def handle_list_skills(_cursor, _ctx, _state), do: Process.sleep(:infinity)
    def handle_get_skill(_uri, _ctx, state), do: {:ok, state[:skill]}
    def handle_read_resource(uri, _ctx, _state), do: {:ok, [%{"uri" => uri, "text" => "ok"}]}
  end

  defmodule MissingGetHandler do
    def init(opts), do: {:ok, opts}
    def handle_list_skills(_cursor, _ctx, _state), do: {:ok, [], nil}
    def handle_read_resource(uri, _ctx, _state), do: {:ok, [%{"uri" => uri, "text" => "ok"}]}
  end

  defmodule MissingReadHandler do
    def init(opts), do: {:ok, opts}
    def handle_list_skills(_cursor, _ctx, _state), do: {:ok, [], nil}
    def handle_get_skill(_uri, _ctx, _state), do: {:error, -32_602, "not found"}
  end

  defmodule NoDirectoryHandler do
    @behaviour MCP.Server.Handler

    def init(opts), do: {:ok, opts}
    def handle_list_skills(_cursor, _ctx, _state), do: {:ok, [], nil}
    def handle_get_skill(_uri, _ctx, _state), do: {:error, -32_602, "not found"}
    def handle_read_resource(uri, _ctx, _state), do: {:ok, [%{"uri" => uri, "text" => "ok"}]}
  end

  setup do
    skill = %{
      "uri" => "skill://acme/demo/SKILL.md",
      "frontmatter" => %{"name" => "demo", "description" => "Demo"},
      "resources" => [
        %{
          "uri" => "skill://acme/demo/SKILL.md",
          "digest" => "sha256:" <> String.duplicate("a", 64),
          "size" => 4
        }
      ]
    }

    {:ok, skill: skill}
  end

  test "configuration advertises Skills only with its complete callback family", %{skill: skill} do
    assert {:ok, config} = enabled_config(Handler, skill: skill, test_pid: self())
    assert config.capabilities.extensions[@extension] == %{}

    assert Config.build(MissingGetHandler, extensions: %{@extension => %{}}) ==
             {:error, {:invalid_skills_extension, :missing_get_callback}}

    assert Config.build(MissingReadHandler, extensions: %{@extension => %{}}) ==
             {:error, {:invalid_skills_extension, :missing_read_resource_callback}}

    assert Config.build(NoDirectoryHandler,
             extensions: %{@extension => %{"directoryRead" => true}}
           ) == {:error, {:invalid_skills_extension, :missing_directory_read_callback}}

    assert Config.build(Handler, extensions: %{@extension => %{"unknown" => true}}) ==
             {:error, {:invalid_skills_extension, :invalid_settings}}
  end

  test "an implemented directory callback remains unreachable unless explicitly advertised", %{
    skill: skill
  } do
    assert {:ok, config} = enabled_config(Handler, skill: skill, test_pid: self())

    assert response =
             dispatch(config, "resources/directory/read", %{"uri" => "skill://acme/demo"})

    assert response["error"]["code"] == -32_601
    refute_receive {:read_directory, _, _, _}
  end

  test "routes list, get, and directory with identity and exact 2026 envelopes", %{skill: skill} do
    assert {:ok, config} =
             enabled_config(Handler,
               skill: skill,
               test_pid: self(),
               next_cursor: "next",
               directory_read: true,
               cache_defaults: {500, "private"}
             )

    list = dispatch(config, "skills/list", %{"cursor" => "page-1"}, "alice")["result"]
    assert_receive {:list_skills, "page-1", "alice"}
    assert list["skills"] == [skill]
    assert list["nextCursor"] == "next"
    assert list["resultType"] == "complete"
    assert list["ttlMs"] == 500
    assert list["cacheScope"] == "private"

    get = dispatch(config, "skills/get", %{"uri" => skill["uri"]}, "bob")["result"]
    assert_receive {:get_skill, _, "bob"}
    assert get == %{"resultType" => "complete", "skill" => skill}
    refute Map.has_key?(get, "ttlMs")

    directory =
      dispatch(config, "resources/directory/read", %{"uri" => "skill://acme/demo"}, "carol")[
        "result"
      ]

    assert_receive {:read_directory, "skill://acme/demo", nil, "carol"}
    assert directory["resultType"] == "complete"
    refute Map.has_key?(directory, "ttlMs")
  end

  test "invalid author output is logged and becomes an internal error", %{skill: skill} do
    invalid = put_in(skill, ["resources", Access.at(0), "digest"], "sha256:BAD")
    assert {:ok, config} = enabled_config(Handler, skill: invalid, test_pid: self())

    log =
      capture_log(fn ->
        response = dispatch(config, "skills/list", %{})
        assert response["error"]["code"] == -32_603
        assert response["error"]["message"] == "Internal error"
      end)

    assert log =~ "callback=handle_list_skills"
  end

  test "Skills callbacks have a bounded timeout that is logged and user-visible", %{skill: skill} do
    assert {:ok, config} =
             enabled_config(SlowHandler,
               skill: skill,
               skills_callback_timeout: 10
             )

    log =
      capture_log(fn ->
        response = dispatch(config, "skills/list", %{})
        assert response["error"]["code"] == -32_603
        assert response["error"]["message"] == "Internal error"
      end)

    assert log =~ "callback=handle_list_skills timeout_ms=10"
  end

  test "legacy projection retains extension behavior and removes 2026 result fields", %{
    skill: skill
  } do
    assert {:ok, config} =
             enabled_config(Handler,
               skill: skill,
               test_pid: self(),
               cache_defaults: {500, "private"}
             )

    request = %Request{id: 7, method: "skills/list", params: %{}}
    context = %ToolContext{request_id: 7, identity: "legacy"}

    assert {:reply, %{"result" => result}} = LegacyDispatch.dispatch(request, context, config)
    assert result["skills"] == [skill]
    refute Map.has_key?(result, "resultType")
    refute Map.has_key?(result, "ttlMs")
    refute Map.has_key?(result, "cacheScope")
    assert_receive {:list_skills, nil, "legacy"}
  end

  defp enabled_config(handler, opts) do
    {directory_read, opts} = Keyword.pop(opts, :directory_read, false)
    {cache_defaults, opts} = Keyword.pop(opts, :cache_defaults, {0, "public"})
    {callback_timeout, handler_opts} = Keyword.pop(opts, :skills_callback_timeout, 30_000)

    Config.build(handler,
      handler_opts: handler_opts,
      extensions: %{@extension => maybe_directory(directory_read)},
      cache_defaults: cache_defaults,
      skills_callback_timeout: callback_timeout
    )
  end

  defp maybe_directory(true), do: %{"directoryRead" => true}
  defp maybe_directory(false), do: %{}

  defp dispatch(config, method, params, identity \\ nil) do
    params = Map.put(params, "_meta", meta())
    request = %Request{id: 1, method: method, params: params}
    context = %ToolContext{request_id: 1, identity: identity}
    assert {:reply, response} = Dispatch.dispatch(request, context, config)
    response
  end

  defp meta do
    %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }
  end
end
