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

  test "serializes concurrent legacy initialize requests until the session is bound" do
    bandit =
      start_supervised!(
        {Bandit,
         plug: {__MODULE__.ConcurrentLegacyInitializePlug, test_pid: self()},
         ip: {127, 0, 0, 1},
         port: 0},
        id: :concurrent_legacy_initialize_bandit
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Client, owner: self(), url: "http://127.0.0.1:#{port}/mcp"},
          id: :concurrent_legacy_initialize_client
        )
      )

    initialize = fn id ->
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "client", "version" => "1.0.0"}
        }
      }
    end

    first = Task.async(fn -> Client.send_message(client, initialize.(1)) end)
    assert_receive {:unbound_legacy_initialize, request, 1}, 1_000

    second = Task.async(fn -> Client.send_message(client, initialize.(2)) end)
    assert_legacy_initialize_counts(client, 1, 1)
    refute_receive {:unbound_legacy_initialize, _request, _id}, 100

    send(request, :release_initialize)
    assert :ok = Task.await(first)
    assert_receive {:mcp_message, %{"id" => 1}}, 1_000

    assert_receive {:bound_legacy_initialize, "legacy-session", 2}, 1_000
    assert :ok = Task.await(second)
    refute_receive {:unbound_legacy_initialize, _request, _id}
  end

  test "advances a queued legacy initialize when the active caller dies" do
    {client, initialize} = start_concurrent_legacy_client(self(), :dead_initializer_client)

    first = spawn(fn -> Client.send_message(client, initialize.(1)) end)
    first_ref = Process.monitor(first)
    assert_receive {:unbound_legacy_initialize, first_request, 1}, 1_000

    second = Task.async(fn -> Client.send_message(client, initialize.(2)) end)
    assert_legacy_initialize_counts(client, 1, 1)
    refute_receive {:unbound_legacy_initialize, _request, 2}, 100

    Process.exit(first, :kill)
    assert_receive {:DOWN, ^first_ref, :process, ^first, :killed}, 1_000
    assert_receive {:unbound_legacy_initialize, second_request, 2}, 1_000

    send(first_request, :release_initialize)
    send(second_request, :release_initialize)
    assert :ok = Task.await(second)
    assert Process.alive?(client)
  end

  test "advances a queued legacy initialize when the active HTTP request fails" do
    {client, initialize} =
      start_concurrent_legacy_client(self(), :failed_initializer_client)

    first = Task.async(fn -> Client.send_message(client, initialize.(1)) end)
    assert_receive {:unbound_legacy_initialize, first_request, 1}, 1_000

    second = Task.async(fn -> Client.send_message(client, initialize.(2)) end)
    assert_legacy_initialize_counts(client, 1, 1)
    refute_receive {:unbound_legacy_initialize, _request, 2}, 100

    send(first_request, {:fail_initialize, 503})
    assert {:error, {:http_error, 503, _body}} = Task.await(first)
    assert_receive {:unbound_legacy_initialize, second_request, 2}, 1_000

    send(second_request, :release_initialize)
    assert :ok = Task.await(second)
    assert Process.alive?(client)
  end

  test "advances a queued legacy initialize when the active POST task exits" do
    {client, initialize} =
      start_concurrent_legacy_client(self(), :exited_initializer_client)

    first = Task.async(fn -> Client.send_message(client, initialize.(1)) end)
    assert_receive {:unbound_legacy_initialize, first_request, 1}, 1_000

    second = Task.async(fn -> Client.send_message(client, initialize.(2)) end)
    assert_legacy_initialize_counts(client, 1, 1)
    refute_receive {:unbound_legacy_initialize, _request, 2}, 100

    state = :sys.get_state(client)
    [{_ref, operation}] = Map.to_list(state.post_tasks)
    Process.exit(operation.task_pid, :kill)
    send(first_request, :release_initialize)

    assert {:error, {:post_task_exit, :killed}} = Task.await(first)
    assert_receive {:unbound_legacy_initialize, second_request, 2}, 1_000

    send(second_request, :release_initialize)
    assert :ok = Task.await(second)
    assert Process.alive?(client)
  end

  test "skips a queued initialize with invalid deferred headers and advances the next" do
    {client, initialize} =
      start_concurrent_legacy_client(self(), :invalid_deferred_headers_client,
        security_policy: [max_concurrent_requests: 3]
      )

    first = Task.async(fn -> Client.send_message(client, initialize.(1)) end)
    assert_receive {:unbound_legacy_initialize, first_request, 1}, 1_000

    invalid_message =
      put_in(initialize.(2), ["params", "arguments"], %{"limit" => "not-an-integer"})

    descriptor = %{header: "Limit", path: ["limit"], type: "integer"}

    invalid =
      Task.async(fn ->
        Client.send_message(client, invalid_message, routing_headers: [descriptor])
      end)

    third = Task.async(fn -> Client.send_message(client, initialize.(3)) end)
    assert_legacy_initialize_counts(client, 1, 2)

    send(first_request, :release_initialize)
    assert :ok = Task.await(first)

    assert {:error, {:invalid_routing_argument, "mcp-param-limit", _reason}} =
             Task.await(invalid)

    assert_receive {:bound_legacy_initialize, "legacy-session", 3}, 1_000
    assert :ok = Task.await(third)
    assert_legacy_initialize_counts(client, 0, 0)
    assert Process.alive?(client)
  end

  test "counts a queued legacy initialize toward the ordinary request limit" do
    {client, initialize} =
      start_concurrent_legacy_client(self(), :ordinary_request_limit_client,
        security_policy: [max_concurrent_requests: 2]
      )

    first = Task.async(fn -> Client.send_message(client, initialize.(1)) end)
    assert_receive {:unbound_legacy_initialize, first_request, 1}, 1_000

    second = Task.async(fn -> Client.send_message(client, initialize.(2)) end)
    assert_legacy_initialize_counts(client, 1, 1)
    refute_receive {:unbound_legacy_initialize, _request, 2}, 100

    ordinary = %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "tools/list",
      "params" => %{}
    }

    assert {:error, :request_limit_reached} = Client.send_message(client, ordinary)

    send(first_request, :release_initialize)
    assert :ok = Task.await(first)
    assert_receive {:bound_legacy_initialize, "legacy-session", 2}, 1_000
    assert :ok = Task.await(second)
  end

  test "bounds active and queued legacy initializes and frees abandoned queue slots" do
    {client, initialize} =
      start_concurrent_legacy_client(self(), :bounded_initializer_client,
        security_policy: [max_concurrent_requests: 2]
      )

    first = Task.async(fn -> Client.send_message(client, initialize.(1)) end)
    assert_receive {:unbound_legacy_initialize, first_request, 1}, 1_000

    abandoned = spawn(fn -> Client.send_message(client, initialize.(2)) end)
    abandoned_ref = Process.monitor(abandoned)
    assert_legacy_initialize_counts(client, 1, 1)
    refute_receive {:unbound_legacy_initialize, _request, 2}, 100

    assert {:error, :request_limit_reached} = Client.send_message(client, initialize.(3))

    Process.exit(abandoned, :kill)
    assert_receive {:DOWN, ^abandoned_ref, :process, ^abandoned, :killed}, 1_000
    assert_legacy_initialize_counts(client, 1, 0)

    replacement = Task.async(fn -> Client.send_message(client, initialize.(4)) end)
    assert_legacy_initialize_counts(client, 1, 1)
    refute_receive {:unbound_legacy_initialize, _request, 4}, 100

    send(first_request, :release_initialize)
    assert :ok = Task.await(first)
    assert_receive {:bound_legacy_initialize, "legacy-session", 4}, 1_000
    assert :ok = Task.await(replacement)
    assert Process.alive?(client)
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

  defp assert_legacy_initialize_counts(client, active, queued, attempts \\ 100)

  defp assert_legacy_initialize_counts(client, active, queued, attempts) when attempts > 0 do
    state = :sys.get_state(client)
    counts = {map_size(state.post_tasks), :queue.len(state.pending_legacy_initializes)}

    if counts == {active, queued} do
      assert counts == {active, queued}
    else
      Process.sleep(10)
      assert_legacy_initialize_counts(client, active, queued, attempts - 1)
    end
  end

  defp assert_legacy_initialize_counts(client, active, queued, 0) do
    state = :sys.get_state(client)

    assert {map_size(state.post_tasks), :queue.len(state.pending_legacy_initializes)} ==
             {active, queued}
  end

  defp start_concurrent_legacy_client(test_pid, id, client_opts \\ []) do
    bandit =
      start_supervised!(
        {Bandit,
         plug: {__MODULE__.ConcurrentLegacyInitializePlug, test_pid: test_pid},
         ip: {127, 0, 0, 1},
         port: 0},
        id: {id, :bandit}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    opts =
      Keyword.merge(
        [owner: self(), url: "http://127.0.0.1:#{port}/mcp"],
        client_opts
      )

    client = start_supervised!(Supervisor.child_spec({Client, opts}, id: id))

    initialize = fn request_id ->
      %{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "client", "version" => "1.0.0"}
        }
      }
    end

    {client, initialize}
  end
end

defmodule MCP.Transport.StreamableHTTPClientTest.ConcurrentLegacyInitializePlug do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, ": connected\n\n")
  end

  def call(%Plug.Conn{method: "DELETE"} = conn, _opts),
    do: Plug.Conn.send_resp(conn, 200, "")

  def call(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    message = Jason.decode!(body)
    test_pid = Keyword.fetch!(opts, :test_pid)

    case List.keyfind(conn.req_headers, "mcp-session-id", 0) do
      nil ->
        send(test_pid, {:unbound_legacy_initialize, self(), message["id"]})

        status =
          receive do
            :release_initialize -> 200
            {:fail_initialize, status} -> status
          end

        response = %{
          "jsonrpc" => "2.0",
          "id" => message["id"],
          "result" => %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "serverInfo" => %{"name" => "legacy", "version" => "1.0.0"}
          }
        }

        conn
        |> Plug.Conn.put_resp_header("mcp-session-id", "legacy-session")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(response))

      {"mcp-session-id", session_id} ->
        send(test_pid, {:bound_legacy_initialize, session_id, message["id"]})
        Plug.Conn.send_resp(conn, 202, "")
    end
  end
end
