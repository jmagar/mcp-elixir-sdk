defmodule MCP.Transport.StreamableHTTPClientTest do
  use ExUnit.Case, async: true

  alias MCP.Test.{DelayedResponsePlug, HTTPResponsePlug, LegacySessionCapturePlug}
  alias MCP.Test.RequestCapturePlug
  alias MCP.Transport.StreamableHTTP.Client

  setup do
    bandit =
      start_supervised!(
        {Bandit, plug: {RequestCapturePlug, test_pid: self()}, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    url = "http://127.0.0.1:#{port}/mcp"
    client = start_supervised!({Client, owner: self(), url: url})

    %{client: client, url: url}
  end

  test "sends Mcp-Method for every JSON-RPC method", %{client: client} do
    headers = send_and_capture(client, "tools/list", %{})

    assert header(headers, "mcp-method") == "tools/list"
    assert header(headers, "mcp-name") == nil
  end

  test "takes MCP-Protocol-Version from the authoritative request body", %{client: client} do
    params = %{
      "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2099-01-01"}
    }

    headers = send_and_capture(client, "tools/list", params)

    assert header(headers, "mcp-protocol-version") == "2099-01-01"
  end

  test "sends params.name as Mcp-Name for tools/call", %{client: client} do
    headers = send_and_capture(client, "tools/call", %{"name" => "weather"})

    assert header(headers, "mcp-name") == "weather"
  end

  test "sends params.name as Mcp-Name for prompts/get", %{client: client} do
    headers = send_and_capture(client, "prompts/get", %{"name" => "review"})

    assert header(headers, "mcp-name") == "review"
  end

  test "sends params.uri as Mcp-Name for resources/read", %{client: client} do
    headers = send_and_capture(client, "resources/read", %{"uri" => "file:///guide.md"})

    assert header(headers, "mcp-name") == "file:///guide.md"
  end

  test "Base64-sentinel encodes a non-ASCII Mcp-Name", %{client: client} do
    headers = send_and_capture(client, "tools/call", %{"name" => "天气"})

    assert header(headers, "mcp-name") == "=?base64?5aSp5rCU?="
  end

  test "Base64-sentinel encodes unsafe ASCII Mcp-Name values", %{client: client} do
    cases = [
      {" padded ", "=?base64?IHBhZGRlZCA=?="},
      {"line1\nline2", "=?base64?bGluZTEKbGluZTI=?="},
      {"=?base64?literal?=", "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?="}
    ]

    for {name, expected} <- cases do
      headers = send_and_capture(client, "tools/call", %{"name" => name})
      assert header(headers, "mcp-name") == expected
    end
  end

  test "rejects case-insensitive extra-header collisions with SDK-owned headers", %{url: url} do
    reserved_names = [
      "Content-Type",
      "ACCEPT",
      "MCP-Protocol-Version",
      "Mcp-Method",
      "mcp-NAME",
      "MCP-Param-Tenant"
    ]

    for name <- reserved_names do
      child_spec =
        Supervisor.child_spec(
          {Client, owner: self(), url: url, headers: [{name, "host-value"}]},
          id: {:colliding_header_client, name}
        )

      assert {:error, {{:reserved_extra_header, ^name}, _child}} = start_supervised(child_spec)
    end
  end

  test "preserves non-reserved extra headers", %{url: url} do
    child_spec =
      Supervisor.child_spec(
        {Client, owner: self(), url: url, headers: [{"x-tenant", "acme"}]},
        id: :custom_header_client
      )

    client = start_supervised!(child_spec)
    headers = send_and_capture(client, "tools/list", %{})

    assert header(headers, "x-tenant") == "acme"
  end

  test "legacy initialize binds both session id and negotiated protocol version" do
    bandit =
      start_supervised!(
        {Bandit, plug: {LegacySessionCapturePlug, test_pid: self()}, ip: {127, 0, 0, 1}, port: 0},
        id: :legacy_session_capture_bandit
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Client, owner: self(), url: "http://127.0.0.1:#{port}/mcp"},
          id: :legacy_session_capture_client
        )
      )

    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "client", "version" => "1.0.0"}
      }
    }

    assert :ok = Client.send_message(client, initialize)
    assert_receive {:legacy_captured_request, first_headers, ^initialize}
    assert header(first_headers, "mcp-protocol-version") == "2025-11-25"
    assert_receive {:mcp_message, %{"id" => 1}}

    initialized = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    assert :ok = Client.send_message(client, initialized)
    assert_receive {:legacy_captured_request, next_headers, ^initialized}
    assert header(next_headers, "mcp-session-id") == "legacy-session"
    assert header(next_headers, "mcp-protocol-version") == "2025-11-25"
  end

  test "does not add method or name routing headers to JSON-RPC responses", %{client: client} do
    message = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}

    assert :ok = Client.send_message(client, message)
    assert_receive {:captured_request, headers, ^message}
    assert header(headers, "mcp-method") == nil
    assert header(headers, "mcp-name") == nil
  end

  test "rejects a result-bearing JSON-RPC body on a non-success HTTP status" do
    body = %{"jsonrpc" => "2.0", "id" => 99, "result" => %{"ok" => true}}

    bandit =
      start_supervised!(
        {Bandit, plug: {HTTPResponsePlug, status: 500, body: body}, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    child_spec =
      Supervisor.child_spec(
        {Client, owner: self(), url: "http://127.0.0.1:#{port}/mcp"},
        id: :non_success_result_client
      )

    client = start_supervised!(child_spec)
    message = %{"jsonrpc" => "2.0", "id" => 99, "method" => "tools/list", "params" => %{}}

    assert {:error, {:http_error, 500, ^body}} = Client.send_message(client, message)
    refute_receive {:mcp_message, ^body}
  end

  test "a cancelled slow POST does not head-of-line block later requests" do
    bandit =
      start_supervised!(
        {Bandit,
         plug: {DelayedResponsePlug, test_pid: self(), delayed_id: 1}, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Client, owner: self(), url: "http://127.0.0.1:#{port}/mcp"},
          id: :concurrent_post_client
        )
      )

    first =
      Task.async(fn ->
        Client.send_message(client, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list",
          "params" => %{}
        })
      end)

    assert_receive {:delayed_request_started, delayed_request}, 1_000
    Task.shutdown(first, :brutal_kill)

    second = %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}}
    assert :ok = Client.send_message(client, second)
    assert_receive {:mcp_message, %{"id" => 2}}, 1_000

    send(delayed_request, :release_delayed_request)
  end

  test "emits a selected validated custom parameter header", %{client: client} do
    message = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "weather", "arguments" => %{"region" => "us-east"}}
    }

    descriptors = [%{header: "Region", path: ["region"], type: "string"}]

    assert :ok = Client.send_message(client, message, routing_headers: descriptors)
    assert_receive {:captured_request, headers, ^message}
    assert header(headers, "mcp-param-region") == "us-east"
  end

  test "encodes nested string, boolean, and safe-integer routing values", %{client: client} do
    message = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "weather",
        "arguments" => %{"route" => %{"region" => "北"}, "fresh" => false, "limit" => 42}
      }
    }

    descriptors = [
      %{header: "Region", path: ["route", "region"], type: "string"},
      %{header: "Fresh", path: ["fresh"], type: "boolean"},
      %{header: "Limit", path: ["limit"], type: "integer"}
    ]

    assert :ok = Client.send_message(client, message, routing_headers: descriptors)
    assert_receive {:captured_request, headers, ^message}
    assert header(headers, "mcp-param-region") == "=?base64?5YyX?="
    assert header(headers, "mcp-param-fresh") == "false"
    assert header(headers, "mcp-param-limit") == "42"
  end

  test "omits null custom values and rejects invalid or unsafe present values", %{client: client} do
    descriptor = %{header: "Limit", path: ["limit"], type: "integer"}

    null_message = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "weather", "arguments" => %{"limit" => nil}}
    }

    assert :ok = Client.send_message(client, null_message, routing_headers: [descriptor])
    assert_receive {:captured_request, headers, ^null_message}
    assert header(headers, "mcp-param-limit") == nil

    for value <- ["42", 9_007_199_254_740_992] do
      message = put_in(null_message, ["params", "arguments", "limit"], value)

      assert {:error, {:invalid_routing_argument, "mcp-param-limit", _reason}} =
               Client.send_message(client, message, routing_headers: [descriptor])

      refute_receive {:captured_request, _headers, ^message}
    end
  end

  defp send_and_capture(client, method, params) do
    message = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    assert :ok = Client.send_message(client, message)
    assert_receive {:captured_request, headers, ^message}

    headers
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn
      {^name, value} -> value
      _header -> nil
    end)
  end
end
