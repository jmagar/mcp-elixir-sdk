defmodule MCP.Transport.LegacySessionHardeningTest do
  use ExUnit.Case, async: false

  alias MCP.Server.Connection
  alias MCP.Test.{BlockingLegacyHandler, StatelessHandler}
  alias MCP.Transport.StreamableHTTP.LegacySession
  alias MCP.Transport.StreamableHTTP.LegacySessionManager
  alias MCP.Transport.StreamableHTTP.Plug, as: MCPPlug

  @legacy_version "2025-11-25"

  test "Plug options can be escaped into a compiled Plug.Builder pipeline" do
    module = Module.concat(__MODULE__, "Compiled#{System.unique_integer([:positive])}")

    quoted =
      quote do
        defmodule unquote(module) do
          use Plug.Builder

          plug(MCP.Transport.StreamableHTTP.Plug,
            server_mod: MCP.Test.StatelessHandler,
            enable_json_response: true
          )
        end
      end

    assert [{^module, _bytecode}] = Code.compile_quoted(quoted)
  end

  test "a legacy session remains bound to the authenticated principal" do
    config =
      MCPPlug.init(
        server_mod: StatelessHandler,
        enable_json_response: true,
        handler_opts: fn conn -> [identity: conn.assigns[:principal]] end
      )

    initialize = legacy_post(config, initialize_request(), nil, :alice)
    [session_id] = Plug.Conn.get_resp_header(initialize, "mcp-session-id")

    denied =
      legacy_post(
        config,
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}},
        session_id,
        :bob
      )

    assert denied.status == 403

    denied_get = legacy_session_request(config, :get, session_id, :bob)
    assert denied_get.status == 403

    denied_delete = legacy_session_request(config, :delete, session_id, :bob)
    assert denied_delete.status == 403

    allowed =
      legacy_post(
        config,
        %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list", "params" => %{}},
        session_id,
        :alice
      )

    assert allowed.status == 200
    assert legacy_session_request(config, :delete, session_id, :alice).status == 200
    assert MCPPlug.legacy_sessions(config) == []
  end

  test "failed initialize does not mint or retain a session" do
    config = MCPPlug.init(server_mod: StatelessHandler, enable_json_response: true)
    request = put_in(initialize_request(), ["params", "protocolVersion"], "unsupported")

    response = legacy_post(config, request, nil, nil)

    assert response.status == 400
    assert Plug.Conn.get_resp_header(response, "mcp-session-id") == []
    assert MCPPlug.legacy_sessions(config) == []
  end

  test "canonical hosts and origins are configurable and missing headers are rejected" do
    config =
      MCPPlug.init(
        server_mod: StatelessHandler,
        enable_json_response: true,
        allowed_hosts: ["tower.example"],
        allowed_origins: ["https://tower.example"]
      )

    accepted =
      :post
      |> Plug.Test.conn("https://tower.example/mcp", Jason.encode!(initialize_request()))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("origin", "https://tower.example")
      |> Plug.Conn.put_req_header("mcp-protocol-version", @legacy_version)
      |> MCPPlug.call(config)

    assert accepted.status == 200

    loopback_with_port =
      :post
      |> Plug.Test.conn("http://127.0.0.1:43001/mcp", Jason.encode!(initialize_request()))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1:43001")
      |> Plug.Conn.put_req_header("mcp-protocol-version", @legacy_version)
      |> MCPPlug.call(MCPPlug.init(server_mod: StatelessHandler, enable_json_response: true))

    assert loopback_with_port.status == 200

    rejected =
      :post
      |> Plug.Test.conn("/mcp", Jason.encode!(initialize_request()))
      |> Map.put(:req_headers, [])
      |> MCPPlug.call(config)

    assert rejected.status == 403
  end

  test "origin allowlists preserve the effective port" do
    config =
      MCPPlug.init(
        server_mod: StatelessHandler,
        enable_json_response: true,
        allowed_hosts: ["tower.example"],
        allowed_origins: ["https://app.example:8443"]
      )

    assert origin_request(config, "https://app.example:8443").status == 200
    assert origin_request(config, "https://app.example:9999").status == 403
  end

  test "session capacity and idle expiry are enforced by the runtime manager" do
    config =
      MCPPlug.init(
        server_mod: StatelessHandler,
        enable_json_response: true,
        legacy_session_limit: 1,
        legacy_session_idle_timeout: 1_000
      )

    first = legacy_post(config, initialize_request(), nil, nil)
    assert first.status == 200
    [{_session_id, server}] = MCPPlug.legacy_sessions(config)
    monitor_ref = Process.monitor(server)

    second = legacy_post(config, initialize_request(), nil, nil)
    assert second.status == 503
    assert Plug.Conn.get_resp_header(second, "mcp-session-id") == []

    future = System.monotonic_time(:millisecond) + 1_001
    assert :ok = LegacySessionManager.sweep(config.legacy_session_manager, future)
    assert MCPPlug.legacy_sessions(config) == []
    assert_receive {:DOWN, ^monitor_ref, :process, ^server, :shutdown}, 1_000
  end

  test "manager shutdown terminates all owned session processes" do
    name = Module.concat(__MODULE__, "Manager#{System.unique_integer([:positive])}")
    _manager = start_supervised!({LegacySessionManager, name: name})

    config =
      MCPPlug.init(
        server_mod: StatelessHandler,
        enable_json_response: true,
        legacy_session_manager: name
      )

    assert legacy_post(config, initialize_request(), nil, nil).status == 200
    [{_session_id, server}] = MCPPlug.legacy_sessions(config)
    monitor_ref = Process.monitor(server)

    stop_supervised!(LegacySessionManager)

    assert_receive {:DOWN, ^monitor_ref, :process, ^server, :shutdown}, 1_000
  end

  test "manager outages are surfaced instead of masquerading as no sessions" do
    name = Module.concat(__MODULE__, "Unavailable#{System.unique_integer([:positive])}")
    _manager = start_supervised!({LegacySessionManager, name: name})

    config =
      MCPPlug.init(
        server_mod: StatelessHandler,
        enable_json_response: true,
        legacy_session_manager: name
      )

    stop_supervised!(LegacySessionManager)

    assert {:error, {:session_manager_unavailable, _reason}} = MCPPlug.legacy_sessions(config)
    assert legacy_post(config, initialize_request(), nil, nil).status == 503
  end

  test "endpoint owner shutdown reclaims that endpoint's sessions" do
    endpoint_owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    config =
      MCPPlug.init(
        server_mod: StatelessHandler,
        enable_json_response: true,
        legacy_endpoint_owner: endpoint_owner
      )

    assert legacy_post(config, initialize_request(), nil, nil).status == 200
    [{_session_id, server}] = MCPPlug.legacy_sessions(config)
    monitor_ref = Process.monitor(server)

    send(endpoint_owner, :stop)

    assert_receive {:DOWN, ^monitor_ref, :process, ^server, :shutdown}, 1_000
    assert MCPPlug.legacy_sessions(config) == []
  end

  test "timed out POST and GET waiters are removed inside the session" do
    {:ok, session} = LegacySession.start(BlockingLegacyHandler, [test_pid: self()], [])
    on_exit(fn -> stop_session(session) end)
    initialize_direct(session)

    request = %{
      "jsonrpc" => "2.0",
      "id" => 9,
      "method" => "tools/call",
      "params" => %{"name" => "block", "arguments" => %{}}
    }

    assert {:error, :timeout} = LegacySession.deliver(session, request, 10)
    assert_receive {:legacy_handler_blocked, server}, 1_000
    assert :sys.get_state(session.transport).pending_posts == %{}

    assert {:error, :timeout} = LegacySession.next_event(session, 10)
    assert :sys.get_state(session.transport).event_waiter == nil
    send(server, :release_legacy_handler)
  end

  test "request-scoped notification buffering is bounded" do
    {:ok, session} = LegacySession.start(BlockingLegacyHandler, [test_pid: self()], [])
    on_exit(fn -> stop_session(session) end)
    initialize_direct(session)

    task =
      Task.async(fn ->
        LegacySession.deliver(
          session,
          %{
            "jsonrpc" => "2.0",
            "id" => 11,
            "method" => "tools/call",
            "params" => %{"name" => "block", "arguments" => %{}}
          },
          5_000
        )
      end)

    assert_receive {:legacy_handler_blocked, server}, 1_000
    message = %{"jsonrpc" => "2.0", "method" => "notifications/progress", "params" => %{}}

    for _index <- 1..256 do
      assert :ok = LegacySession.send_request_notification(session.transport, 11, message)
    end

    assert {:error, :queue_overflow} =
             LegacySession.send_request_notification(session.transport, 11, message)

    send(server, :release_legacy_handler)
    assert {:ok, _response, notifications} = Task.await(task)
    assert length(notifications) == 256
  end

  defp initialize_request do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @legacy_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "hardening-test", "version" => "1.0.0"}
      }
    }
  end

  defp legacy_post(config, message, session_id, principal) do
    conn =
      :post
      |> Plug.Test.conn("http://localhost/mcp", Jason.encode!(message))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("origin", "http://localhost")
      |> Plug.Conn.put_req_header("mcp-protocol-version", @legacy_version)
      |> Plug.Conn.assign(:principal, principal)

    conn =
      if session_id,
        do: Plug.Conn.put_req_header(conn, "mcp-session-id", session_id),
        else: conn

    MCPPlug.call(conn, config)
  end

  defp origin_request(config, origin) do
    :post
    |> Plug.Test.conn("https://tower.example/mcp", Jason.encode!(initialize_request()))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("origin", origin)
    |> Plug.Conn.put_req_header("mcp-protocol-version", @legacy_version)
    |> MCPPlug.call(config)
  end

  defp legacy_session_request(config, method, session_id, principal) do
    accept = if method == :get, do: "text/event-stream", else: "application/json"

    method
    |> Plug.Test.conn("http://localhost/mcp")
    |> Plug.Conn.put_req_header("accept", accept)
    |> Plug.Conn.put_req_header("origin", "http://localhost")
    |> Plug.Conn.put_req_header("mcp-protocol-version", @legacy_version)
    |> Plug.Conn.put_req_header("mcp-session-id", session_id)
    |> Plug.Conn.assign(:principal, principal)
    |> MCPPlug.call(config)
  end

  defp initialize_direct(session) do
    assert {:ok, %{"result" => %{"protocolVersion" => @legacy_version}}, []} =
             LegacySession.deliver(session, initialize_request(), 1_000)

    assert :accepted =
             LegacySession.deliver(
               session,
               %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
               1_000
             )
  end

  defp stop_session(session) do
    if Process.alive?(session.server), do: Connection.close(session.server)
    if Process.alive?(session.transport), do: LegacySession.close(session.transport)
  end
end
