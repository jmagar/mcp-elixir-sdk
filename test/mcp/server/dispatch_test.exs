defmodule MCP.Server.DispatchTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Capabilities.ServerCapabilities
  alias MCP.Protocol.Messages.{Notification, Request}
  alias MCP.Protocol.Types.Implementation
  alias MCP.Server.Dispatch
  alias MCP.Server.ToolContext
  alias MCP.Test.StatelessHandler

  @version "2026-07-28"

  defp config do
    {:ok, state} = StatelessHandler.init([])

    %{
      handler_module: StatelessHandler,
      handler_state: state,
      server_info: %Implementation{name: "mcp_elixir_sdk", version: "2.0.0"},
      capabilities: %ServerCapabilities{},
      instructions: nil
    }
  end

  defp ctx(identity \\ nil), do: %ToolContext{request_id: 1, identity: identity}

  defp meta(version \\ @version) do
    %{
      "io.modelcontextprotocol/protocolVersion" => version,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }
  end

  defp req(method, params), do: %Request{id: 1, method: method, params: params}

  defp call_tool(name, args, identity) do
    params = %{"name" => name, "arguments" => args, "_meta" => meta()}
    {:reply, resp} = Dispatch.dispatch(req("tools/call", params), ctx(identity), config())
    resp
  end

  defp tool_text(resp), do: resp["result"]["content"] |> hd() |> Map.get("text")

  # --- MC-1: per-request context reaches the callback ---

  test "MC-1 — context identity reaches tools/call" do
    assert tool_text(call_tool("whoami", %{}, "PM")) == "PM"
  end

  test "MC-1 — context reaches a non-tool path (prompts/get)" do
    params = %{"name" => "who", "arguments" => %{}, "_meta" => meta()}
    {:reply, resp} = Dispatch.dispatch(req("prompts/get", params), ctx("REVIEWER"), config())
    text = resp["result"]["messages"] |> hd() |> get_in(["content", "text"])
    assert text == "REVIEWER"
  end

  # --- MC-4: a model-supplied identity arg NEVER reaches ctx.identity ---

  test "MC-4 — tool-arg identity does not override ctx.identity (spoof dropped)" do
    assert tool_text(call_tool("whoami_with_arg", %{"identity" => "spoof"}, "REAL")) == "REAL"
  end

  test "MC-4 — with no pipeline identity, a spoof arg still yields empty (never spoof)" do
    text = tool_text(call_tool("whoami_with_arg", %{"identity" => "spoof"}, nil))
    assert text == ""
    refute text == "spoof"
  end

  test "MC-4 — prompts/get: a competing arguments.identity does not override ctx.identity (AC3′)" do
    params = %{"name" => "who", "arguments" => %{"identity" => "spoof"}, "_meta" => meta()}
    {:reply, resp} = Dispatch.dispatch(req("prompts/get", params), ctx("REVIEWER"), config())
    text = resp["result"]["messages"] |> hd() |> get_in(["content", "text"])
    assert text == "REVIEWER"
    refute text == "spoof"
  end

  # --- MC-3: per-request isolation ---

  test "MC-3 — concurrent requests see their own identity; no leakage" do
    assert tool_text(call_tool("whoami", %{}, "PM")) == "PM"
    assert tool_text(call_tool("whoami", %{}, "REVIEWER")) == "REVIEWER"
  end

  # --- Removed methods: stateless behaviour, no legacy path ---

  test "initialize is removed → method not found (-32601)" do
    {:reply, resp} = Dispatch.dispatch(req("initialize", %{}), ctx(), config())
    assert resp["error"]["code"] == -32_601
  end

  test "ping and logging/setLevel are removed → method not found (-32601)" do
    {:reply, ping_resp} = Dispatch.dispatch(req("ping", %{}), ctx(), config())

    {:reply, log_resp} =
      Dispatch.dispatch(req("logging/setLevel", %{"level" => "info"}), ctx(), config())

    assert ping_resp["error"]["code"] == -32_601
    assert log_resp["error"]["code"] == -32_601
  end

  # --- Per-request version gate ---

  test "request without required _meta fails as invalid params (-32602)" do
    {:reply, resp} =
      Dispatch.dispatch(req("tools/call", %{"name" => "whoami"}), ctx("PM"), config())

    assert resp["error"]["code"] == -32_602
  end

  test "non-object _meta is rejected without raising" do
    {:reply, resp} =
      Dispatch.dispatch(
        req("tools/list", %{"_meta" => "not-an-object"}),
        ctx(),
        config()
      )

    assert resp["error"]["code"] == -32_602
  end

  test "old-shape (2025-11-25) version fails fast (-32022)" do
    params = %{"name" => "whoami", "arguments" => %{}, "_meta" => meta("2025-11-25")}
    {:reply, resp} = Dispatch.dispatch(req("tools/call", params), ctx("PM"), config())
    assert resp["error"]["code"] == -32_022
  end

  # --- server/discover: required version gate and schema-shaped result ---

  test "server/discover: schema shape (supportedVersions + CacheableResult fields; serverInfo in _meta)" do
    {:reply, resp} =
      Dispatch.dispatch(req("server/discover", %{"_meta" => meta()}), ctx(), config())

    result = resp["result"]

    assert result["supportedVersions"] == [@version]
    assert result["resultType"] == "complete"
    assert result["ttlMs"] == 0
    assert result["cacheScope"] == "public"
    assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "mcp_elixir_sdk"
    # the pre-fix (wrong) shape must be gone
    refute Map.has_key?(result, "protocolVersions")
    refute Map.has_key?(result, "serverInfo")
  end

  test "prompts/get supports input-required and validates continuation state" do
    first_params = %{"name" => "needs_input", "arguments" => %{}, "_meta" => meta()}
    {:reply, first} = Dispatch.dispatch(req("prompts/get", first_params), ctx(), config())

    assert first["result"] == %{
             "resultType" => "input_required",
             "inputRequests" => %{
               "prompt_input" => %{"method" => "elicitation/create", "params" => %{}}
             },
             "requestState" => "prompt-state-1"
           }

    retry_params =
      Map.merge(first_params, %{
        "requestState" => "prompt-state-1",
        "inputResponses" => %{"prompt_input" => %{"value" => "ready"}}
      })

    {:reply, final} = Dispatch.dispatch(req("prompts/get", retry_params), ctx(), config())
    assert get_in(final, ["result", "resultType"]) == "complete"
    assert get_in(final, ["result", "messages", Access.at(0), "content", "text"]) == "ready"

    {:reply, invalid} =
      Dispatch.dispatch(
        req("prompts/get", %{retry_params | "requestState" => "tampered"}),
        ctx(),
        config()
      )

    assert invalid["error"]["code"] == -32_602
  end

  test "resources/read supports input-required and validates continuation state" do
    first_params = %{"uri" => "mem://needs-input", "_meta" => meta()}
    {:reply, first} = Dispatch.dispatch(req("resources/read", first_params), ctx(), config())

    assert first["result"] == %{
             "resultType" => "input_required",
             "inputRequests" => %{
               "resource_input" => %{"method" => "elicitation/create", "params" => %{}}
             },
             "requestState" => "resource-state-1"
           }

    retry_params =
      Map.merge(first_params, %{
        "requestState" => "resource-state-1",
        "inputResponses" => %{"resource_input" => %{"value" => "ready"}}
      })

    {:reply, final} = Dispatch.dispatch(req("resources/read", retry_params), ctx(), config())
    assert get_in(final, ["result", "resultType"]) == "complete"
    assert get_in(final, ["result", "contents", Access.at(0), "text"]) == "ready"

    {:reply, invalid} =
      Dispatch.dispatch(
        req("resources/read", %{retry_params | "requestState" => "tampered"}),
        ctx(),
        config()
      )

    assert invalid["error"]["code"] == -32_602
  end

  test "tools/call accepts a full typed result with lossless structured content" do
    params = %{"name" => "structured", "arguments" => %{}, "_meta" => meta()}
    {:reply, response} = Dispatch.dispatch(req("tools/call", params), ctx(), config())

    assert response["result"] == %{
             "content" => [],
             "structuredContent" => false,
             "isError" => false,
             "vendorResult" => nil,
             "resultType" => "complete"
           }
  end

  test "MRTR fields with invalid wire types fail before handler invocation" do
    requests = [
      {"tools/call", %{"name" => "needs_input", "arguments" => %{}}},
      {"prompts/get", %{"name" => "needs_input", "arguments" => %{}}},
      {"resources/read", %{"uri" => "mem://needs-input"}}
    ]

    for {method, params} <- requests,
        malformed <- [
          %{"requestState" => 42},
          %{"inputResponses" => []},
          %{"requestState" => nil}
        ] do
      params = params |> Map.merge(malformed) |> Map.put("_meta", meta())
      {:reply, response} = Dispatch.dispatch(req(method, params), ctx(), config())
      assert response["error"]["code"] == -32_602
    end
  end

  test "resources/read preserves structured handler error data" do
    params = %{"uri" => "mem://missing", "_meta" => meta()}
    {:reply, response} = Dispatch.dispatch(req("resources/read", params), ctx(), config())

    assert response["error"] == %{
             "code" => -32_602,
             "message" => "resource not found",
             "data" => %{"uri" => "mem://missing"}
           }
  end

  # --- MC-1 depth: context reaches ALL EIGHT identity-capable callbacks ---

  test "MC-1 depth — the per-request context reaches all eight identity-capable callbacks" do
    id = "PM"

    checks = [
      {"tools/list", %{}, fn r -> get_in(r, ["tools", Access.at(0), "boundIdentity"]) end},
      {"tools/call", %{"name" => "whoami", "arguments" => %{}},
       fn r -> get_in(r, ["content", Access.at(0), "text"]) end},
      {"resources/list", %{}, fn r -> get_in(r, ["resources", Access.at(0), "name"]) end},
      {"resources/read", %{"uri" => "mem://res"},
       fn r -> get_in(r, ["contents", Access.at(0), "text"]) end},
      {"resources/templates/list", %{},
       fn r -> get_in(r, ["resourceTemplates", Access.at(0), "name"]) end},
      {"prompts/list", %{}, fn r -> get_in(r, ["prompts", Access.at(0), "description"]) end},
      {"prompts/get", %{"name" => "who", "arguments" => %{}},
       fn r -> get_in(r, ["messages", Access.at(0), "content", "text"]) end},
      {"completion/complete", %{"ref" => %{}, "argument" => %{}},
       fn r -> get_in(r, ["completion", "values", Access.at(0)]) end}
    ]

    for {method, extra, extract} <- checks do
      params = Map.put(extra, "_meta", meta())
      {:reply, resp} = Dispatch.dispatch(req(method, params), ctx(id), config())
      assert extract.(resp["result"]) == id, "context identity did not reach #{method}"
    end
  end

  test "F3 — a handler missing the required context arity is a contract error (method-not-found), not a silent legacy call" do
    defmodule NoCtxHandler do
      @behaviour MCP.Server.Handler
      def init(_), do: {:ok, %{}}
      # only the legacy 2-arity form — NOT the stateless context arity
      def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}
    end

    cfg = %{config() | handler_module: NoCtxHandler}
    params = %{"_meta" => meta()}
    {:reply, resp} = Dispatch.dispatch(req("tools/list", params), ctx("PM"), cfg)
    assert resp["error"]["code"] == -32_601
  end

  # --- notifications are SDK-internal no-ops ---

  test "notifications/initialized is tolerated as a no-op (handshake removed)" do
    notif = %Notification{method: "notifications/initialized", params: nil}
    assert :noreply = Dispatch.dispatch(notif, ctx(), config())
  end
end
