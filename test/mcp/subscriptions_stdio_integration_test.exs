defmodule MCP.SubscriptionsStdioIntegrationTest do
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Client.SubscriptionHandle
  alias MCP.Protocol.Messages.Subscriptions.ListenResult
  alias MCP.Protocol.Methods
  alias MCP.Protocol.Types.SubscriptionFilter
  alias MCP.Server.Connection
  alias MCP.Server.SubscriptionPublisher
  alias MCP.Test.{BridgeTransport, MockTransport, SubscriptionHandler}

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  setup do
    client_supervisor =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :client_subscriptions)

    server_supervisor =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :server_subscriptions)

    registry = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :duplicate, name: registry})

    {client_transport, server_transport} = BridgeTransport.create_pair()

    server =
      start_supervised!(
        {Connection,
         transport: {BridgeTransport, pid: server_transport},
         handler: {SubscriptionHandler, test_pid: self()},
         identity: :stdio_principal,
         subscription_supervisor: server_supervisor,
         subscription_registry: registry,
         subscription_endpoint: :stdio_test}
      )

    client =
      start_supervised!(
        {Client,
         transport: {BridgeTransport, pid: client_transport},
         subscription_supervisor: client_supervisor}
      )

    %{
      client: client,
      client_transport: client_transport,
      registry: registry,
      server: server,
      server_supervisor: server_supervisor,
      server_transport: server_transport
    }
  end

  test "multiplexes subscriptions with acknowledgment-first filtering", context do
    {:ok, tools} =
      Client.listen_subscriptions(
        context.client,
        %SubscriptionFilter{tools_list_changed: true}
      )

    {:ok, resources} =
      Client.listen_subscriptions(
        context.client,
        %SubscriptionFilter{resource_subscriptions: ["file:///guide.md"]}
      )

    assert_receive {:subscription_authorized, 1, :stdio_principal}, 1_000
    assert_receive {:subscription_authorized, 2, :stdio_principal}, 1_000

    assert {:ok, tools_ack} = SubscriptionHandle.next(tools, 1_000)
    assert tools_ack["method"] == Methods.subscriptions_acknowledged()
    assert tools_ack["params"]["_meta"][@subscription_id_key] == 1

    assert {:ok, resources_ack} = SubscriptionHandle.next(resources, 1_000)
    assert resources_ack["method"] == Methods.subscriptions_acknowledged()
    assert resources_ack["params"]["_meta"][@subscription_id_key] == 2

    assert :ok =
             SubscriptionPublisher.publish(
               context.registry,
               :stdio_test,
               Methods.resources_updated(),
               %{"uri" => "file:///guide.md"}
             )

    assert :ok =
             SubscriptionPublisher.publish(
               context.registry,
               :stdio_test,
               Methods.tools_list_changed(),
               %{}
             )

    assert {:ok, resource_event} = SubscriptionHandle.next(resources, 1_000)
    assert resource_event["method"] == Methods.resources_updated()
    assert resource_event["params"]["_meta"][@subscription_id_key] == 2

    assert {:ok, tool_event} = SubscriptionHandle.next(tools, 1_000)
    assert tool_event["method"] == Methods.tools_list_changed()
    assert tool_event["params"]["_meta"][@subscription_id_key] == 1
  end

  test "blocked subscription authorization does not stall the connection", context do
    {client_transport, server_transport} = BridgeTransport.create_pair()

    server =
      start_supervised!(
        {Connection,
         transport: {BridgeTransport, pid: server_transport},
         handler: {SubscriptionHandler, test_pid: self(), block_authorization?: true},
         identity: :stdio_principal,
         subscription_supervisor: context.server_supervisor,
         subscription_registry: context.registry,
         subscription_endpoint: :stdio_test,
         handler_timeout: 100},
        id: make_ref()
      )

    {:ok, ^client_transport} = BridgeTransport.start_link(pid: client_transport, owner: self())

    :ok =
      BridgeTransport.send_message(client_transport, %{
        "jsonrpc" => "2.0",
        "id" => 91,
        "method" => Methods.subscriptions_listen(),
        "params" => %{
          "notifications" => %{"toolsListChanged" => true},
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      })

    assert_receive {:subscription_authorized, 91, :stdio_principal}, 1_000
    assert %Connection{} = :sys.get_state(server)

    :ok =
      BridgeTransport.send_message(client_transport, %{
        "jsonrpc" => "2.0",
        "id" => 92,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "race-test", "version" => "1"}
        }
      })

    assert_receive {:mcp_message, %{"id" => 92, "error" => %{"code" => -32_600}}}, 1_000

    assert_receive {:mcp_message, %{"id" => 91, "error" => %{"message" => "Internal error"}}},
                   1_000

    assert :sys.get_state(server).handler_tasks == %{}
  end

  test "close sends a scoped stdio cancellation and leaves siblings active", context do
    filter = %SubscriptionFilter{tools_list_changed: true}
    {:ok, first} = Client.listen_subscriptions(context.client, filter)
    {:ok, second} = Client.listen_subscriptions(context.client, filter)

    assert {:ok, _ack} = SubscriptionHandle.next(first, 1_000)
    assert {:ok, _ack} = SubscriptionHandle.next(second, 1_000)
    assert :ok = SubscriptionHandle.close(first)

    assert :ok = await_registry_count(context, 1)

    assert :ok =
             SubscriptionPublisher.publish(
               context.registry,
               :stdio_test,
               Methods.tools_list_changed(),
               %{}
             )

    assert {:ok, event} = SubscriptionHandle.next(second, 1_000)
    assert event["params"]["_meta"][@subscription_id_key] == 2
  end

  test "server graceful closure delivers the final listen result", context do
    {:ok, handle} =
      Client.listen_subscriptions(
        context.client,
        %SubscriptionFilter{tools_list_changed: true}
      )

    assert {:ok, _ack} = SubscriptionHandle.next(handle, 1_000)
    assert :ok = Connection.close_subscription(context.server, 1)

    assert {:ok, %ListenResult{} = result} = SubscriptionHandle.next(handle, 1_000)
    assert result.meta[@subscription_id_key] == 1
    assert SubscriptionHandle.next(handle, 0) == {:error, :closed}
  end

  test "transport loss terminates a subscription without synthetic success", context do
    {:ok, handle} =
      Client.listen_subscriptions(
        context.client,
        %SubscriptionFilter{tools_list_changed: true}
      )

    assert {:ok, _ack} = SubscriptionHandle.next(handle, 1_000)
    assert :ok = BridgeTransport.close(context.client_transport)

    assert SubscriptionHandle.next(handle, 1_000) ==
             {:error, {:transport_closed, :normal}}
  end

  @tag capture_log: true
  test "server queue overflow terminates the stdio subscription with an error", context do
    server_supervisor = :sys.get_state(context.server).subscription_supervisor
    client_supervisor = :sys.get_state(context.client).subscription_supervisor
    {client_transport, server_transport} = BridgeTransport.create_pair()

    overflow_server =
      start_supervised!(
        {Connection,
         transport: {BridgeTransport, pid: server_transport},
         handler: {SubscriptionHandler, test_pid: self()},
         identity: :stdio_principal,
         subscription_supervisor: server_supervisor,
         subscription_registry: context.registry,
         subscription_endpoint: :stdio_overflow_test,
         subscription_queue_limit: 1},
        id: :overflow_server
      )

    overflow_client =
      start_supervised!(
        {Client,
         transport: {BridgeTransport, pid: client_transport},
         subscription_supervisor: client_supervisor},
        id: :overflow_client
      )

    {:ok, handle} =
      Client.listen_subscriptions(
        overflow_client,
        %SubscriptionFilter{tools_list_changed: true}
      )

    assert {:ok, _ack} = SubscriptionHandle.next(handle, 1_000)

    [{worker, _value}] =
      Registry.lookup(context.registry, {:mcp_subscriptions, :stdio_overflow_test})

    worker_ref = Process.monitor(worker)

    :ok = :sys.suspend(overflow_server)

    on_exit(fn ->
      try do
        :sys.resume(overflow_server)
      catch
        :exit, _reason -> :ok
      end
    end)

    for sequence <- 1..2 do
      assert :ok =
               SubscriptionPublisher.publish(
                 context.registry,
                 :stdio_overflow_test,
                 Methods.tools_list_changed(),
                 %{"sequence" => sequence}
               )
    end

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :queue_overflow}, 1_000
    :ok = :sys.resume(overflow_server)

    assert {:error, %MCP.Protocol.Error{} = error} = SubscriptionHandle.next(handle, 1_000)
    assert error.code == -32_603

    assert error.data["reason"] in [
             "subscription_queue_overflow",
             "subscription_closed_abruptly"
           ]
  end

  test "client rejects subscriptions without consumer-owned supervision", context do
    client =
      start_supervised!(
        {Client, transport: {BridgeTransport, pid: context.client_transport}},
        id: :unconfigured_subscription_client
      )

    assert Client.listen_subscriptions(client, %SubscriptionFilter{}) ==
             {:error, :subscriptions_not_configured}
  end

  test "missing and unsupported subscription metadata are rejected before authorization",
       context do
    {:ok, _transport} =
      BridgeTransport.start_link(pid: context.client_transport, owner: self())

    for {id, meta, expected_code} <- [
          {91, nil, -32_602},
          {92,
           %{
             "io.modelcontextprotocol/protocolVersion" => "2025-11-25",
             "io.modelcontextprotocol/clientCapabilities" => %{}
           }, -32_022}
        ] do
      params = %{"notifications" => %{"toolsListChanged" => true}}
      params = if meta, do: Map.put(params, "_meta", meta), else: params

      assert :ok =
               BridgeTransport.send_message(context.client_transport, %{
                 "jsonrpc" => "2.0",
                 "id" => id,
                 "method" => Methods.subscriptions_listen(),
                 "params" => params
               })

      assert_receive {:mcp_message, %{"id" => ^id, "error" => %{"code" => ^expected_code}}},
                     1_000

      refute_receive {:subscription_authorized, ^id, _identity}
    end

    assert Registry.lookup(context.registry, {:mcp_subscriptions, :stdio_test}) == []
  end

  test "server rejects invalid immutable subscription configuration", context do
    common = [
      transport: {MockTransport, []},
      handler: {SubscriptionHandler, test_pid: self()}
    ]

    assert_connection_start_error(
      common ++ [subscription_supervisor: context.server],
      :incomplete_subscription_configuration
    )

    assert_connection_start_error(
      common ++ [subscription_queue_limit: 0],
      {:invalid_subscription_queue_limit, 0}
    )

    assert_connection_start_error(
      common ++
        [
          subscription_supervisor: context.server,
          subscription_registry: :not_a_registry
        ],
      :invalid_registry
    )
  end

  defp synchronize(context) do
    _ = :sys.get_state(context.client)
    _ = :sys.get_state(context.client_transport)
    _ = :sys.get_state(context.server_transport)
    _ = :sys.get_state(context.server)
  end

  defp await_registry_count(context, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000
    synchronize(context)
    actual = Registry.lookup(context.registry, {:mcp_subscriptions, :stdio_test}) |> length()

    cond do
      actual == expected ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        :erlang.yield()
        await_registry_count(context, expected, deadline)

      true ->
        {:error, {:registry_count, actual}}
    end
  end

  defp assert_connection_start_error(opts, expected) do
    previous = Process.flag(:trap_exit, true)

    try do
      assert {:error, ^expected} = Connection.start_link(opts)

      receive do
        {:EXIT, _pid, ^expected} -> :ok
      after
        0 -> :ok
      end
    after
      Process.flag(:trap_exit, previous)
    end
  end
end
