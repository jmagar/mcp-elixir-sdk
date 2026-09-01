defmodule MCP.Transport.LegacySessionHardeningTest do
  use ExUnit.Case, async: false

  alias MCP.Server.Connection
  alias MCP.Test.{BlockingLegacyHandler, StatelessHandler}
  alias MCP.Transport.StreamableHTTP.LegacySession
  alias MCP.Transport.StreamableHTTP.LegacySessionManager
  alias MCP.Transport.StreamableHTTP.Plug, as: MCPPlug

  @legacy_version "2025-11-25"

  defmodule BlockingInitHandler do
    @behaviour MCP.Server.Handler

    @impl true
    def init(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:legacy_init_blocked, self()})

      receive do
        :release_legacy_init -> {:ok, %{}}
      end
    end
  end

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

  test "a legacy session rejects stale non-identity authorization context" do
    config =
      MCPPlug.init(
        server_mod: StatelessHandler,
        enable_json_response: true,
        handler_opts: fn conn ->
          [
            identity: conn.assigns[:principal],
            role: conn.assigns[:role],
            authorization_context: %{role: conn.assigns[:role]}
          ]
        end
      )

    initialize = legacy_post_with_role(config, initialize_request(), nil, :alice, :admin)
    [session_id] = Plug.Conn.get_resp_header(initialize, "mcp-session-id")

    denied =
      legacy_post_with_role(
        config,
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}},
        session_id,
        :alice,
        :viewer
      )

    assert denied.status == 403
  end

  test "request-scoped handler options do not invalidate a legacy session" do
    config =
      MCPPlug.init(
        server_mod: StatelessHandler,
        enable_json_response: true,
        handler_opts: fn conn ->
          [identity: conn.assigns[:principal], trace_id: System.unique_integer()]
        end
      )

    initialize = legacy_post(config, initialize_request(), nil, :alice)
    [session_id] = Plug.Conn.get_resp_header(initialize, "mcp-session-id")

    response =
      legacy_post(
        config,
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}},
        session_id,
        :alice
      )

    assert response.status == 200
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

  test "slow initialization for one endpoint does not block another endpoint" do
    name = Module.concat(__MODULE__, "ConcurrentManager#{System.unique_integer([:positive])}")
    manager = start_supervised!({LegacySessionManager, name: name})
    test_pid = self()

    slow =
      Task.async(fn ->
        LegacySessionManager.create(
          manager,
          :slow_endpoint,
          :alice,
          BlockingInitHandler,
          [test_pid: test_pid],
          [],
          manager_limits(test_pid)
        )
      end)

    assert_receive {:legacy_init_blocked, initializer}, 1_000

    assert {:ok, _session_id, fast_session} =
             LegacySessionManager.create(
               manager,
               :fast_endpoint,
               :bob,
               StatelessHandler,
               [],
               [],
               manager_limits(test_pid)
             )

    assert Process.alive?(fast_session.server)
    send(initializer, :release_legacy_init)
    assert {:ok, _session_id, _slow_session} = Task.await(slow, 1_000)
  end

  test "parallel creates reserve capacity before session startup completes" do
    name = Module.concat(__MODULE__, "CapacityManager#{System.unique_integer([:positive])}")
    manager = start_supervised!({LegacySessionManager, name: name})
    limits = manager_limits(self(), session_limit: 1, per_identity_limit: 1)

    tasks =
      for _ <- 1..16 do
        Task.async(fn ->
          LegacySessionManager.create(
            manager,
            :capacity_endpoint,
            :alice,
            StatelessHandler,
            [],
            [],
            limits
          )
        end)
      end

    results = Task.await_many(tasks, 2_000)
    assert 1 == Enum.count(results, &match?({:ok, _id, _session}, &1))
    assert 15 == Enum.count(results, &(&1 == {:error, :session_limit}))
    assert [_session] = LegacySessionManager.list(manager, :capacity_endpoint)
  end

  test "initialization deadlines release reserved capacity" do
    name = Module.concat(__MODULE__, "DeadlineManager#{System.unique_integer([:positive])}")
    manager = start_supervised!({LegacySessionManager, name: name})
    limits = manager_limits(self(), initialization_timeout: 25, session_limit: 1)

    assert {:error, :initialization_timeout} =
             LegacySessionManager.create(
               manager,
               :deadline_endpoint,
               :alice,
               BlockingInitHandler,
               [test_pid: self()],
               [],
               limits
             )

    assert_receive {:legacy_init_blocked, _initializer}, 1_000

    assert {:ok, _id, _session} =
             LegacySessionManager.create(
               manager,
               :deadline_endpoint,
               :alice,
               StatelessHandler,
               [],
               [],
               limits
             )
  end

  test "requester death cancels pending initialization and releases capacity" do
    name = Module.concat(__MODULE__, "CallerManager#{System.unique_integer([:positive])}")
    manager = start_supervised!({LegacySessionManager, name: name})
    limits = manager_limits(self(), initialization_timeout: 5_000, session_limit: 1)
    test_pid = self()

    requester =
      spawn(fn ->
        LegacySessionManager.create(
          manager,
          :caller_endpoint,
          :alice,
          BlockingInitHandler,
          [test_pid: test_pid],
          [],
          limits
        )
      end)

    assert_receive {:legacy_init_blocked, _initializer}, 1_000
    Process.exit(requester, :kill)

    assert eventually(fn -> :sys.get_state(manager).pending == %{} end)

    assert {:ok, _id, _session} =
             LegacySessionManager.create(
               manager,
               :caller_endpoint,
               :alice,
               StatelessHandler,
               [],
               [],
               limits
             )
  end

  test "lookup refresh replaces rather than accumulates expiration entries" do
    name = Module.concat(__MODULE__, "ExpiryManager#{System.unique_integer([:positive])}")
    manager = start_supervised!({LegacySessionManager, name: name})
    limits = manager_limits(self())

    assert {:ok, id, _session} =
             LegacySessionManager.create(
               manager,
               :expiry_endpoint,
               :alice,
               StatelessHandler,
               [],
               [],
               limits
             )

    for _ <- 1..1_000 do
      assert {:ok, _session} =
               LegacySessionManager.lookup(manager, :expiry_endpoint, id, :alice)
    end

    state = :sys.get_state(manager)
    assert :gb_sets.size(state.expirations) == map_size(state.sessions)
    assert :gb_sets.size(state.expirations) == 1
  end

  test "failed initialization cleanup returns monitor count to baseline" do
    name = Module.concat(__MODULE__, "MonitorManager#{System.unique_integer([:positive])}")
    manager = start_supervised!({LegacySessionManager, name: name})
    baseline = manager |> Process.info(:monitors) |> elem(1) |> length()
    limits = manager_limits(self(), initialization_timeout: 10)

    for _ <- 1..10 do
      assert {:error, :initialization_timeout} =
               LegacySessionManager.create(
                 manager,
                 :monitor_endpoint,
                 :alice,
                 BlockingInitHandler,
                 [test_pid: self()],
                 [],
                 limits
               )

      assert_receive {:legacy_init_blocked, _initializer}, 1_000
    end

    assert eventually(fn ->
             manager |> Process.info(:monitors) |> elem(1) |> length() == baseline
           end)
  end

  test "atomic manager admission rejects calls beyond the configured ceiling" do
    name = Module.concat(__MODULE__, "AdmissionManager#{System.unique_integer([:positive])}")
    manager = start_supervised!({LegacySessionManager, name: name, max_pending_calls: 1})
    :ok = :sys.suspend(manager)
    admitted = Task.async(fn -> LegacySessionManager.list(manager, :endpoint) end)

    assert eventually(fn ->
             Process.info(manager, :message_queue_len) == {:message_queue_len, 1}
           end)

    assert {:error, :manager_overloaded} = LegacySessionManager.list(manager, :endpoint)
    :ok = :sys.resume(manager)
    assert [] = Task.await(admitted)
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
    {:ok, session} =
      LegacySession.start(BlockingLegacyHandler, [test_pid: self()], [], @legacy_version)

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
    {:ok, session} =
      LegacySession.start(BlockingLegacyHandler, [test_pid: self()], [], @legacy_version)

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

  defp manager_limits(owner, overrides \\ []) do
    Keyword.merge(
      [
        endpoint_owner: owner,
        protocol_version: @legacy_version,
        session_limit: 100,
        per_identity_limit: 100,
        idle_timeout: 60_000,
        absolute_timeout: 60_000
      ],
      overrides
    )
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
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

  defp legacy_post_with_role(config, message, session_id, principal, role) do
    conn =
      :post
      |> Plug.Test.conn("http://localhost/mcp", Jason.encode!(message))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("origin", "http://localhost")
      |> Plug.Conn.put_req_header("mcp-protocol-version", @legacy_version)
      |> Plug.Conn.assign(:principal, principal)
      |> Plug.Conn.assign(:role, role)

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
