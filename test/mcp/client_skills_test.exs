defmodule MCP.ClientSkillsTest do
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Protocol.Messages.Resources.DirectoryReadResult
  alias MCP.Protocol.Messages.Skills.{GetResult, ListResult}
  alias MCP.Test.MockTransport

  @extension "io.modelcontextprotocol/skills"
  @digest "sha256:" <> String.duplicate("a", 64)

  defp start_client do
    {:ok, client} =
      Client.start_link(
        transport: {MockTransport, []},
        client_info: %{name: "skills-client", version: "1.0.0"}
      )

    {client, Client.transport(client)}
  end

  defp connect(client, transport, settings \\ %{}) do
    task = Task.async(fn -> Client.connect(client) end)
    {:ok, [request]} = MockTransport.await_sent(transport, 1)

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => request["id"],
      "result" => %{
        "supportedVersions" => ["2026-07-28"],
        "capabilities" => %{"extensions" => %{@extension => settings}},
        "resultType" => "complete",
        "ttlMs" => 0,
        "cacheScope" => "public",
        "_meta" => %{
          "io.modelcontextprotocol/serverInfo" => %{"name" => "skills", "version" => "1"}
        }
      }
    })

    assert {:ok, _result} = Task.await(task)
  end

  defp skill(name) do
    uri = "https://skills.example/skills/#{name}/SKILL.md"

    %{
      "uri" => uri,
      "frontmatter" => %{"name" => name, "description" => "description", "custom" => [1]},
      "resources" => [%{"uri" => uri, "digest" => @digest, "size" => 10}],
      "_meta" => %{"opaque" => true}
    }
  end

  defp inject_response(transport, request, result) do
    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => request["id"],
      "result" => result
    })
  end

  test "gates skills and directory methods on negotiated extension settings" do
    {client, transport} = start_client()

    assert {:error, {:extension_not_negotiated, @extension}} = Client.list_skills(client)
    assert MockTransport.sent_messages(transport) == []

    connect(client, transport)

    assert {:error, {:extension_capability_not_negotiated, "directoryRead"}} =
             Client.read_resource_directory(client, "file:///skills/demo")

    assert length(MockTransport.sent_messages(transport)) == 1
  end

  test "rejects invalid public page bounds before sending a request" do
    {client, transport} = start_client()
    connect(client, transport)

    assert {:error, {:invalid_pagination_bound, :max_items, 0}} =
             Client.list_skills(client, max_items: 0)

    assert {:error, {:invalid_pagination_bound, :max_bytes, "large"}} =
             Client.list_skills(client, max_bytes: "large")

    assert length(MockTransport.sent_messages(transport)) == 1
  end

  test "rejects empty URIs and malformed negotiated settings locally" do
    {client, transport} = start_client()
    connect(client, transport, %{"directoryRead" => "yes"})

    assert {:error, {:invalid_skill_uri, ""}} = Client.get_skill(client, "")

    assert {:error, {:invalid_resource_directory_uri, ""}} =
             Client.read_resource_directory(client, "")

    assert {:error, {:invalid_extension_capability, @extension, _settings}} =
             Client.list_skills(client)

    assert length(MockTransport.sent_messages(transport)) == 1
  end

  test "sends list/get/directory params and safely decodes typed results" do
    {client, transport} = start_client()
    connect(client, transport, %{"directoryRead" => true})

    list_task =
      Task.async(fn -> Client.list_skills(client, cursor: "c1", meta: %{"trace" => 1}) end)

    {:ok, messages} = MockTransport.await_sent(transport, 2)
    list_request = List.last(messages)
    assert list_request["method"] == "skills/list"
    assert list_request["params"]["cursor"] == "c1"
    assert list_request["params"]["_meta"]["trace"] == 1

    inject_response(transport, list_request, %{
      "skills" => [skill("demo")],
      "resultType" => "complete"
    })

    assert {:ok, %ListResult{skills: [decoded]}} = Task.await(list_task)
    assert decoded.frontmatter["custom"] == [1]

    get_task = Task.async(fn -> Client.get_skill(client, decoded.uri, meta: %{"trace" => 2}) end)
    {:ok, messages} = MockTransport.await_sent(transport, 3)
    get_request = List.last(messages)
    assert get_request["method"] == "skills/get"
    assert get_request["params"]["uri"] == decoded.uri
    inject_response(transport, get_request, %{"skill" => skill("demo")})
    assert {:ok, %GetResult{skill: %{uri: uri}}} = Task.await(get_task)
    assert uri == decoded.uri

    directory_task =
      Task.async(fn ->
        Client.read_resource_directory(client, "https://skills.example/skills/demo", cursor: "d1")
      end)

    {:ok, messages} = MockTransport.await_sent(transport, 4)
    directory_request = List.last(messages)
    assert directory_request["method"] == "resources/directory/read"
    assert directory_request["params"]["uri"] == "https://skills.example/skills/demo"
    assert directory_request["params"]["cursor"] == "d1"

    inject_response(transport, directory_request, %{
      "resources" => [%{"uri" => decoded.uri, "name" => "SKILL.md"}]
    })

    assert {:ok, %DirectoryReadResult{resources: [%{name: "SKILL.md"}]}} =
             Task.await(directory_task)
  end

  test "malformed result returns a tagged error without crashing the client" do
    {client, transport} = start_client()
    connect(client, transport)

    task = Task.async(fn -> Client.list_skills(client) end)
    {:ok, messages} = MockTransport.await_sent(transport, 2)
    inject_response(transport, List.last(messages), %{"skills" => [%{"uri" => 42}]})

    assert {:error, {:invalid_skills_list_result, _reason}} = Task.await(task)
    assert Process.alive?(client)
  end

  test "list_all_skills accumulates linearly and rejects cursor cycles" do
    {client, transport} = start_client()
    connect(client, transport)

    task = Task.async(fn -> Client.list_all_skills(client, max_pages: 3, timeout: 2_000) end)
    {:ok, messages} = MockTransport.await_sent(transport, 2)
    first = List.last(messages)
    inject_response(transport, first, %{"skills" => [skill("one")], "nextCursor" => "next"})

    {:ok, messages} = MockTransport.await_sent(transport, 3)
    second = List.last(messages)
    assert second["params"]["cursor"] == "next"
    inject_response(transport, second, %{"skills" => [skill("two")], "nextCursor" => "next"})

    assert {:error, {:skills_pagination_cursor_cycle, "next"}} = Task.await(task)
  end

  test "list_all_skills preserves ordered results across successful pages" do
    {client, transport} = start_client()
    connect(client, transport)

    task = Task.async(fn -> Client.list_all_skills(client, max_pages: 3, timeout: 2_000) end)
    {:ok, messages} = MockTransport.await_sent(transport, 2)

    inject_response(transport, List.last(messages), %{
      "skills" => [skill("one")],
      "nextCursor" => "next"
    })

    {:ok, messages} = MockTransport.await_sent(transport, 3)
    inject_response(transport, List.last(messages), %{"skills" => [skill("two")]})

    assert {:ok, [one, two]} = Task.await(task)
    assert [one.frontmatter["name"], two.frontmatter["name"]] == ["one", "two"]
    assert length(MockTransport.sent_messages(transport)) == 3
  end

  test "list_all_skills stops at the page bound before requesting another page" do
    {client, transport} = start_client()
    connect(client, transport)

    task = Task.async(fn -> Client.list_all_skills(client, max_pages: 1, timeout: 2_000) end)
    {:ok, messages} = MockTransport.await_sent(transport, 2)

    inject_response(transport, List.last(messages), %{
      "skills" => [skill("one")],
      "nextCursor" => "next"
    })

    assert {:error, {:skills_pagination_limit, :pages, 1}} = Task.await(task)
    assert length(MockTransport.sent_messages(transport)) == 2
  end

  test "list_all_skills preserves an explicit starting cursor" do
    {client, transport} = start_client()
    connect(client, transport)

    task = Task.async(fn -> Client.list_all_skills(client, cursor: "resume", timeout: 2_000) end)
    {:ok, messages} = MockTransport.await_sent(transport, 2)
    request = List.last(messages)
    assert request["params"]["cursor"] == "resume"
    inject_response(transport, request, %{"skills" => [skill("one")]})
    assert {:ok, [_skill]} = Task.await(task)
  end

  test "list_all_skills counts the complete page envelope against max_bytes" do
    {client, transport} = start_client()
    connect(client, transport)

    task = Task.async(fn -> Client.list_all_skills(client, max_bytes: 250, timeout: 2_000) end)
    {:ok, messages} = MockTransport.await_sent(transport, 2)

    inject_response(transport, List.last(messages), %{
      "skills" => [skill("one")],
      "_meta" => %{"padding" => String.duplicate("x", 500)}
    })

    assert {:error, {:skills_pagination_limit, :bytes, 250}} = Task.await(task)
  end

  test "list_all_skills uses one absolute deadline across pages" do
    {client, transport} = start_client()
    connect(client, transport)

    started = System.monotonic_time(:millisecond)
    task = Task.async(fn -> Client.list_all_skills(client, timeout: 200) end)
    {:ok, messages} = MockTransport.await_sent(transport, 2)
    Process.sleep(150)

    inject_response(transport, List.last(messages), %{
      "skills" => [skill("one")],
      "nextCursor" => "next"
    })

    assert {:ok, _messages} = MockTransport.await_sent(transport, 3)
    assert {:error, :timeout} = Task.await(task, 500)
    assert System.monotonic_time(:millisecond) - started < 300
  end

  test "list_all_skills enforces item, byte, and non-progress limits" do
    for {opts, expected, result} <- [
          {[max_items: 1], {:skills_pagination_limit, :items, 1},
           %{"skills" => [skill("one"), skill("two")]}},
          {[max_bytes: 1], {:skills_pagination_limit, :bytes, 1}, %{"skills" => [skill("one")]}},
          {[], {:skills_pagination_non_progress, "next"},
           %{"skills" => [], "nextCursor" => "next"}}
        ] do
      {client, transport} = start_client()
      connect(client, transport)

      task =
        Task.async(fn -> Client.list_all_skills(client, Keyword.put(opts, :timeout, 2_000)) end)

      {:ok, messages} = MockTransport.await_sent(transport, 2)
      inject_response(transport, List.last(messages), result)
      assert {:error, ^expected} = Task.await(task)
    end
  end
end
