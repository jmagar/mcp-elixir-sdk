defmodule MCP.Server.LegacyProtocolHardeningTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Error
  alias MCP.Protocol.Messages.Request
  alias MCP.Server.{Config, Connection, Dispatch, ToolContext}

  alias MCP.Test.{
    BlockingLegacyHandler,
    BridgeTransport,
    FailableTransport,
    LegacyFeatureHandler,
    LegacyMRTRHandler,
    LegacySubscribeOnlyHandler,
    StatelessHandler
  }

  @legacy_version "2025-11-25"
  @stateless_version "2026-07-28"

  test "ordinary notifications do not select or mutate a connection protocol era" do
    {server, client_transport} = start_connection(StatelessHandler)

    send_message(client_transport, notification("notifications/roots/list_changed"))
    send_message(client_transport, initialize(1))

    assert_receive {:mcp_message, %{"id" => 1, "result" => initialize_result}}, 5_000
    assert initialize_result["protocolVersion"] == @legacy_version

    send_message(client_transport, notification("notifications/initialized"))
    BridgeTransport.sync(client_transport)
    _ = :sys.get_state(server)
    send_message(client_transport, notification("notifications/roots/list_changed"))
    send_message(client_transport, request(2, "tools/list", %{}))

    assert_receive {:mcp_message, %{"id" => 2, "result" => result}}, 5_000
    assert is_list(result["tools"])
    refute Map.has_key?(result, "resultType")
  end

  test "2026 discovery capabilities omit legacy logging and resource subscribe" do
    assert {:ok, %{capabilities: capabilities} = config} =
             Config.build(LegacyFeatureHandler, handler_opts: [test_pid: self()])

    assert capabilities.logging == nil
    assert capabilities.resources.subscribe == nil

    params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @stateless_version,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
    }

    request = %Request{id: 1, method: "server/discover", params: params}
    context = %ToolContext{request_id: 1}
    assert {:reply, response} = Dispatch.dispatch(request, context, config)
    refute Map.has_key?(response["result"]["capabilities"], "logging")
    refute get_in(response, ["result", "capabilities", "resources", "subscribe"])
  end

  test "legacy initialize advertises subscribe only for a complete callback pair" do
    {_server, complete_transport} =
      start_connection(LegacyFeatureHandler, handler_opts: [test_pid: self()])

    send_message(complete_transport, initialize(1))
    assert_receive {:mcp_message, %{"result" => complete_result}}, 1_000
    assert get_in(complete_result, ["capabilities", "resources", "subscribe"]) == true
    assert complete_result["capabilities"]["logging"] == %{}

    {_server, incomplete_transport} = start_connection(LegacySubscribeOnlyHandler)
    send_message(incomplete_transport, initialize(2))
    assert_receive {:mcp_message, %{"result" => incomplete_result}}, 1_000
    refute get_in(incomplete_result, ["capabilities", "resources", "subscribe"])
  end

  test "legacy methods reject malformed params without invoking handlers or killing the session" do
    {server, client_transport} =
      start_ready_connection(LegacyFeatureHandler, handler_opts: [test_pid: self()])

    invalid = [
      {2, "resources/subscribe", nil},
      {3, "resources/subscribe", []},
      {4, "resources/subscribe", %{}},
      {5, "resources/subscribe", %{"uri" => 42}},
      {6, "resources/unsubscribe", %{"uri" => ""}},
      {7, "logging/setLevel", %{"level" => "verbose"}},
      {8, "logging/setLevel", %{"level" => 1}},
      {9, "tools/list", []},
      {10, "tools/list", %{"_meta" => []}},
      {11, "ping", []},
      {12, "resources/subscribe", %{"uri" => "file:///bad", "_meta" => []}},
      {13, "logging/setLevel", %{"level" => "info", "_meta" => []}}
    ]

    for {id, method, params} <- invalid do
      send_message(client_transport, request(id, method, params))
      assert_receive {:mcp_message, %{"id" => ^id, "error" => %{"code" => -32_602}}}, 1_000
    end

    refute_receive {:subscribed, _, _}
    refute_receive {:unsubscribed, _, _}
    refute_receive {:log_level, _, _}

    send_message(client_transport, request(14, "ping", %{}))
    assert_receive {:mcp_message, %{"id" => 14, "result" => %{}}}, 1_000
    assert %Connection{} = :sys.get_state(server)
  end

  test "a second initialize is rejected as soon as the first response is sent" do
    {_server, client_transport} = start_connection(StatelessHandler)
    send_message(client_transport, initialize(1))
    assert_receive {:mcp_message, %{"id" => 1, "result" => _}}, 5_000

    send_message(client_transport, initialize(2))
    assert_receive {:mcp_message, %{"id" => 2, "error" => %{"code" => -32_600}}}, 1_000
  end

  test "an invalid stateless request does not prevent later legacy initialization" do
    {_server, client_transport} = start_connection(StatelessHandler)

    send_message(client_transport, request(1, "tools/list", %{}))
    assert_receive {:mcp_message, %{"id" => 1, "error" => %{"code" => -32_602}}}, 1_000

    send_message(client_transport, initialize(2))
    assert_receive {:mcp_message, %{"id" => 2, "result" => result}}, 1_000
    assert result["protocolVersion"] == @legacy_version
  end

  test "malformed decoded envelopes receive an invalid-request response" do
    {_server, client_transport} = start_connection(StatelessHandler)

    send_message(client_transport, %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "result" => %{},
      "error" => %{}
    })

    assert_receive {:mcp_message, %{"id" => 7, "error" => %{"code" => -32_600}}}, 1_000
  end

  test "non-map envelopes receive an error without crashing the connection" do
    {server, client_transport} = start_connection(StatelessHandler)

    send(server, {:mcp_message, []})
    assert_receive {:mcp_message, %{"id" => nil, "error" => %{"code" => -32_600}}}, 1_000

    send_message(client_transport, request(8, "ping", stateless_params()))
    assert_receive {:mcp_message, %{"id" => 8}}, 1_000
    assert Process.alive?(server)
  end

  test "a blocking legacy handler does not block independent connection requests" do
    {_server, client_transport} =
      start_ready_connection(BlockingLegacyHandler, handler_opts: [test_pid: self()])

    send_message(
      client_transport,
      request(2, "tools/call", %{"name" => "block", "arguments" => %{}})
    )

    assert_receive {:legacy_handler_blocked, handler_pid}, 1_000
    send_message(client_transport, request(3, "ping", %{}))
    assert_receive {:mcp_message, %{"id" => 3, "result" => %{}}}, 1_000

    send(handler_pid, :release_legacy_handler)
    assert_receive {:mcp_message, %{"id" => 2, "result" => _}}, 1_000
  end

  test "a duplicate in-flight ordinary request id is rejected without a second callback" do
    {_server, client_transport} =
      start_ready_connection(BlockingLegacyHandler, handler_opts: [test_pid: self()])

    duplicate = request(2, "tools/call", %{"name" => "block", "arguments" => %{}})
    send_message(client_transport, duplicate)
    assert_receive {:legacy_handler_blocked, handler_pid}, 1_000

    send_message(client_transport, duplicate)
    assert_receive {:mcp_message, %{"id" => 2, "error" => %{"code" => -32_600}}}, 1_000
    refute_receive {:legacy_handler_blocked, _second_handler_pid}, 100

    send(handler_pid, :release_legacy_handler)
    assert_receive {:mcp_message, %{"id" => 2, "result" => _}}, 1_000
  end

  test "handler capacity and timeout are bounded and release task state" do
    {server, client_transport} =
      start_ready_connection(BlockingLegacyHandler,
        handler_opts: [test_pid: self()],
        max_concurrent_handlers: 1,
        handler_timeout: 100
      )

    send_message(client_transport, request(2, "tools/call", %{"name" => "block"}))
    assert_receive {:legacy_handler_blocked, _handler_pid}, 1_000

    send_message(client_transport, request(3, "tools/call", %{"name" => "block"}))

    assert_receive {:mcp_message,
                    %{"id" => 3, "error" => %{"data" => "handler capacity reached"}}},
                   1_000

    assert_receive {:mcp_message, %{"id" => 2, "error" => %{"data" => "handler timeout"}}},
                   1_000

    assert :sys.get_state(server).handler_tasks == %{}
  end

  test "configured and public request timeouts reject invalid values without crashing" do
    previous_trap_exit = Process.flag(:trap_exit, true)

    for invalid <- [0, -1, 1.5, :bad, nil] do
      {_client_transport, server_transport} = BridgeTransport.create_pair()

      assert {:error, {:invalid_request_timeout, ^invalid}} =
               Connection.start_link(
                 transport: {BridgeTransport, pid: server_transport},
                 handler: {StatelessHandler, []},
                 request_timeout: invalid
               )
    end

    Process.flag(:trap_exit, previous_trap_exit)

    {server, _client_transport} = start_ready_connection(StatelessHandler)

    for invalid <- [0, -1, 1.5, :bad, nil] do
      assert {:error, {:invalid_timeout, ^invalid}} =
               Connection.request_roots(server, invalid)
    end

    assert %Connection{} = :sys.get_state(server)
  end

  test "server-to-client requests require the negotiated client capability" do
    {server, _client_transport} = start_ready_connection(StatelessHandler)

    for request_fn <- [
          fn -> Connection.request_sampling(server, %{"messages" => []}, 100) end,
          fn -> Connection.request_roots(server, 100) end,
          fn -> Connection.request_elicitation(server, %{"mode" => "form"}, 100) end
        ] do
      assert {:error, %Error{code: -32_021}} = request_fn.()
    end

    refute_receive {:mcp_message, %{"method" => _method}}
  end

  test "elicitation requests require the negotiated mode" do
    {server, client_transport} =
      start_ready_connection(StatelessHandler,
        client_capabilities: %{"elicitation" => %{"form" => %{}}}
      )

    assert {:error, %Error{code: -32_021}} =
             Connection.request_elicitation(server, %{"mode" => "url", "url" => "https://x"}, 100)

    request_task =
      Task.async(fn ->
        Connection.request_elicitation(server, %{"mode" => "form", "message" => "Continue?"}, 500)
      end)

    assert_receive {:mcp_message,
                    %{"id" => request_id, "method" => "elicitation/create"} = request},
                   500

    assert request["params"]["mode"] == "form"

    send_message(client_transport, %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => %{"action" => "accept"}
    })

    assert {:ok, %{"action" => "accept"}} = Task.await(request_task)
  end

  test "legacy empty elicitation capability negotiates form requests" do
    {server, client_transport} =
      start_ready_connection(StatelessHandler,
        client_capabilities: %{"elicitation" => %{}}
      )

    request_task =
      Task.async(fn ->
        Connection.request_elicitation(server, %{"message" => "Continue?"}, 500)
      end)

    assert_receive {:mcp_message, %{"id" => request_id, "method" => "elicitation/create"}}, 500

    send_message(client_transport, %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => %{"action" => "accept"}
    })

    assert {:ok, %{"action" => "accept"}} = Task.await(request_task)
  end

  test "MRTR adapter enforces negotiated capabilities and caps input count" do
    {server, client_transport} =
      start_ready_connection(LegacyMRTRHandler, handler_opts: [test_pid: self()])

    send_message(
      client_transport,
      request(2, "tools/call", %{"name" => "parallel_inputs", "arguments" => %{}})
    )

    assert_receive {:mcp_message, %{"id" => 2, "error" => %{"code" => -32_603}}}, 1_000
    refute_receive {:mcp_message, %{"method" => "roots/list"}}

    {_server, capable_transport} =
      start_ready_connection(LegacyMRTRHandler,
        handler_opts: [test_pid: self()],
        client_capabilities: %{"roots" => %{}}
      )

    send_message(
      capable_transport,
      request(3, "tools/call", %{"name" => "many_inputs", "arguments" => %{}})
    )

    assert_receive {:mcp_message, %{"id" => 3, "error" => %{"code" => -32_602, "data" => data}}},
                   1_000

    assert inspect(data) =~ "too_many_input_requests"
    refute_receive {:mcp_message, %{"method" => "roots/list"}}
    assert %Connection{} = :sys.get_state(server)
  end

  test "MRTR inputs run concurrently under one deadline and leave no pending requests" do
    {server, client_transport} =
      start_ready_connection(LegacyMRTRHandler,
        handler_opts: [test_pid: self()],
        client_capabilities: %{"roots" => %{}},
        request_timeout: 500
      )

    send_message(
      client_transport,
      request(2, "tools/call", %{"name" => "parallel_inputs", "arguments" => %{}})
    )

    requests =
      for _index <- 1..4 do
        assert_receive {:mcp_message, %{"id" => id, "method" => "roots/list"} = message}, 500
        {id, message}
      end

    for {id, _message} <- requests do
      send_message(client_transport, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
    end

    assert_receive {:mcp_message, %{"id" => 2, "result" => _}}, 1_000
    assert_receive {:mrtr_responses, responses}
    assert map_size(responses) == 4
    assert :sys.get_state(server).pending_client_requests == %{}
  end

  test "MRTR deadline applies to the whole bounded resolver and cleans abandoned requests" do
    {server, client_transport} =
      start_ready_connection(LegacyMRTRHandler,
        handler_opts: [test_pid: self()],
        client_capabilities: %{"roots" => %{}},
        request_timeout: 100
      )

    send_message(
      client_transport,
      request(2, "tools/call", %{"name" => "deadline_inputs", "arguments" => %{}})
    )

    for _index <- 1..8 do
      assert_receive {:mcp_message, %{"method" => "roots/list"}}, 500
    end

    assert_receive {:mcp_message, %{"id" => 2, "error" => %{"code" => -32_603}}}, 500
    _ = :sys.get_state(server)
    assert :sys.get_state(server).pending_client_requests == %{}
    refute_receive {:mcp_message, %{"method" => "roots/list"}}
  end

  test "effectful notification APIs return readiness and transport delivery errors" do
    server =
      start_supervised!(
        {Connection,
         transport: {FailableTransport, observer: self()}, handler: {StatelessHandler, []}},
        id: make_ref()
      )

    transport = Connection.transport(server)

    assert {:error, :legacy_client_not_ready} = Connection.notify_tools_changed(server)
    assert {:error, :legacy_client_not_ready} = Connection.log(server, "info", %{})
    assert {:error, :legacy_client_not_ready} = Connection.send_progress(server, "p", 1)

    FailableTransport.inject(transport, initialize(1))
    assert_receive {:mcp_message, %{"id" => 1, "result" => _}}, 1_000
    FailableTransport.inject(transport, notification("notifications/initialized"))
    _ = :sys.get_state(server)

    assert :ok = Connection.notify_tools_changed(server)
    assert_receive {:mcp_message, %{"method" => "notifications/tools/list_changed"}}, 1_000

    :ok = FailableTransport.fail(transport, :closed)
    assert {:error, :closed} = Connection.send_progress(server, "p", 2)
  end

  test "an initialize response send failure terminates without entering initialized state" do
    previous_trap_exit = Process.flag(:trap_exit, true)

    {:ok, server} =
      Connection.start_link(
        transport: {FailableTransport, observer: self()},
        handler: {StatelessHandler, []}
      )

    monitor = Process.monitor(server)
    transport = Connection.transport(server)
    :ok = FailableTransport.fail(transport, :closed)
    :ok = FailableTransport.inject(transport, initialize(1))

    assert_receive {:DOWN, ^monitor, :process, ^server, {:transport_send_failed, :closed}}, 5_000
    refute_receive {:mcp_message, %{"id" => 1}}
    Process.flag(:trap_exit, previous_trap_exit)
  end

  test "a malformed-request error send failure terminates the connection" do
    previous_trap_exit = Process.flag(:trap_exit, true)

    {:ok, server} =
      Connection.start_link(
        transport: {FailableTransport, observer: self()},
        handler: {StatelessHandler, []}
      )

    monitor = Process.monitor(server)
    transport = Connection.transport(server)
    :ok = FailableTransport.fail(transport, :closed)
    :ok = FailableTransport.inject(transport, %{"jsonrpc" => "2.0", "id" => 7})

    assert_receive {:DOWN, ^monitor, :process, ^server, {:transport_send_failed, :closed}}, 5_000
    Process.flag(:trap_exit, previous_trap_exit)
  end

  defp start_ready_connection(handler, opts \\ []) do
    capabilities = Keyword.get(opts, :client_capabilities, %{})
    {server, client_transport} = start_connection(handler, opts)
    send_message(client_transport, initialize(1, capabilities))
    assert_receive {:mcp_message, %{"id" => 1, "result" => _}}, 5_000
    send_message(client_transport, notification("notifications/initialized"))
    BridgeTransport.sync(client_transport)
    _ = :sys.get_state(server)
    {server, client_transport}
  end

  defp start_connection(handler, opts \\ []) do
    {client_transport, server_transport} = BridgeTransport.create_pair()
    handler_opts = Keyword.get(opts, :handler_opts, [])

    connection_opts =
      opts
      |> Keyword.drop([:handler_opts, :client_capabilities])
      |> Keyword.merge(
        transport: {BridgeTransport, pid: server_transport},
        handler: {handler, handler_opts}
      )

    server = start_supervised!({Connection, connection_opts}, id: make_ref())
    {:ok, ^client_transport} = BridgeTransport.start_link(pid: client_transport, owner: self())
    {server, client_transport}
  end

  defp initialize(id, capabilities \\ %{}) do
    request(id, "initialize", %{
      "protocolVersion" => @legacy_version,
      "capabilities" => capabilities,
      "clientInfo" => %{"name" => "hardening-test", "version" => "1.0.0"}
    })
  end

  defp request(id, method, params),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp notification(method), do: %{"jsonrpc" => "2.0", "method" => method}

  defp stateless_params do
    %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @stateless_version,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
    }
  end

  defp send_message(transport, message),
    do: :ok = BridgeTransport.send_message(transport, message)
end
