defmodule MCP.ClientLifecycleTest do
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Client.SubscriptionHandle
  alias MCP.Protocol.Types.SubscriptionFilter
  alias MCP.Test.{BlockingTransport, DelayedResponsePlug, MockTransport}
  alias MCP.Transport.StreamableHTTP.Client, as: HTTPClient

  test "deadline is registered before transport I/O and bounds a blocked send" do
    client =
      start_supervised!(
        {Client,
         transport: {BlockingTransport, observer: self()},
         request_timeout: 2_000,
         client_info: %{name: "deadline-test", version: "1"}}
      )

    call = Task.async(fn -> Client.list_tools(client) end)
    assert_receive {:transport_send_started, %{"method" => "tools/list"}}, 3_000

    state = :sys.get_state(client)
    assert map_size(state.pending_requests) == 1

    assert Enum.all?(state.pending_requests, fn {_id, pending} ->
             is_reference(pending.timeout_ref)
           end)

    assert {:error, :timeout} = Task.await(call, 3_000)
    assert Client.status(client) == :ready
    assert :sys.get_state(client).pending_requests == %{}
  end

  test "raising MRTR callback fails only its operation and leaves client responsive" do
    client =
      start_supervised!(
        {Client,
         transport: {MockTransport, []},
         on_input_required: fn _requests -> raise "resolver failed" end}
      )

    transport = Client.transport(client)
    call = Task.async(fn -> Client.call_tool(client, "needs_input") end)
    request = await_request(transport)

    MockTransport.inject(transport, input_required(request["id"]))

    assert {:error, {:callback_failed, _reason}} = Task.await(call, 1_000)
    assert Client.status(client) == :ready
  end

  test "slow MRTR callback is terminated by the original operation deadline" do
    test_pid = self()

    resolver = fn _requests ->
      send(test_pid, {:resolver_started, self()})

      receive do
        :continue -> []
      end
    end

    client =
      start_supervised!(
        {Client, transport: {MockTransport, []}, on_input_required: resolver, request_timeout: 75}
      )

    transport = Client.transport(client)
    call = Task.async(fn -> Client.call_tool(client, "needs_input") end)
    request = await_request(transport)
    MockTransport.inject(transport, input_required(request["id"]))

    assert_receive {:resolver_started, resolver_pid}, 1_000
    monitor = Process.monitor(resolver_pid)
    assert Client.status(client) == :ready
    assert {:error, :timeout} = Task.await(call, 1_000)
    assert_receive {:DOWN, ^monitor, :process, ^resolver_pid, _reason}, 1_000
    assert Client.status(client) == :ready
  end

  test "raising function notification handler does not crash the client" do
    client =
      start_supervised!(
        {Client,
         transport: {MockTransport, []},
         notification_handler: fn _method, _params -> raise "notification failed" end}
      )

    transport = Client.transport(client)

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/tools/list_changed"
    })

    _ = :sys.get_state(client)
    assert Client.status(client) == :ready
  end

  test "notification callbacks have bounded concurrency under a flood" do
    handler = fn _method, _params ->
      receive do
        :release -> :ok
      end
    end

    client =
      start_supervised!(
        {Client,
         transport: {MockTransport, []},
         notification_handler: handler,
         notification_concurrency: 2}
      )

    transport = Client.transport(client)

    for sequence <- 1..100 do
      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"sequence" => sequence}
      })
    end

    _ = :sys.get_state(client)
    supervisor = :sys.get_state(client).notification_supervisor
    counts = DynamicSupervisor.count_children(supervisor)
    assert counts.active <= 2
    assert Client.status(client) == :ready
  end

  test "trace metadata is merged with reserved per-request metadata unchanged" do
    client = start_supervised!({Client, transport: {MockTransport, []}})
    transport = Client.transport(client)

    trace = %{
      "traceparent" => "00-abc-def-01",
      "tracestate" => "vendor=value",
      "baggage" => "a=b"
    }

    call = Task.async(fn -> Client.list_tools(client, meta: trace) end)
    request = await_request(transport)

    assert Map.take(request["params"]["_meta"], Map.keys(trace)) == trace
    assert request["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => request["id"],
      "result" => %{"tools" => []}
    })

    assert {:ok, _result} = Task.await(call)
  end

  test "repeated identical calls always reach the transport despite cache hints" do
    client = start_supervised!({Client, transport: {MockTransport, []}})
    transport = Client.transport(client)

    for expected_count <- 1..2 do
      call = Task.async(fn -> Client.read_resource(client, "mem://same") end)
      request = await_request(transport, expected_count)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{
          "contents" => [],
          "resultType" => "complete",
          "ttlMs" => 60_000,
          "cacheScope" => "private"
        }
      })

      assert {:ok, %{"ttlMs" => 60_000, "cacheScope" => "private"}} = Task.await(call)
    end

    assert length(MockTransport.sent_messages(transport)) == 2
  end

  test "invalid per-call metadata is rejected without crashing the client" do
    client = start_supervised!({Client, transport: {MockTransport, []}})

    assert Client.call_tool(client, "echo", %{}, meta: [not: "a map"]) ==
             {:error, {:invalid_meta, [not: "a map"]}}

    assert Client.status(client) == :ready
  end

  test "closing a subscription cancels HTTP work blocked before response headers" do
    bandit =
      start_supervised!(
        {Bandit,
         plug: {DelayedResponsePlug, test_pid: self(), delayed_id: 1}, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    subscription_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    client =
      start_supervised!(
        {Client,
         transport: {HTTPClient, url: "http://127.0.0.1:#{port}/mcp"},
         subscription_supervisor: subscription_supervisor}
      )

    filter = %SubscriptionFilter{tools_list_changed: true}
    assert {:ok, handle} = Client.listen_subscriptions(client, filter, timeout: 1_000)
    assert_receive {:delayed_request_started, _request}, 5_000

    transport = Client.transport(client)

    [{_id, subscription}] =
      transport |> :sys.get_state() |> Map.fetch!(:subscriptions) |> Map.to_list()

    stream_ref = Process.monitor(subscription.task)

    assert :ok = SubscriptionHandle.close(handle)
    assert_receive {:DOWN, ^stream_ref, :process, _pid, _reason}, 1_000
    _ = :sys.get_state(client)

    assert Client.status(client) == :ready
    assert :sys.get_state(transport).subscriptions == %{}
  end

  test "a blocking pluggable subscription transport cannot freeze the client" do
    subscription_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    client =
      start_supervised!(
        {Client,
         transport: {BlockingTransport, observer: self()},
         subscription_supervisor: subscription_supervisor}
      )

    open =
      Task.async(fn ->
        Client.listen_subscriptions(
          client,
          %SubscriptionFilter{tools_list_changed: true},
          timeout: 50
        )
      end)

    assert_receive {:transport_send_started, %{"method" => "subscriptions/listen"}}, 1_000
    assert {:error, :timeout} = Task.await(open, 1_000)
    assert Client.status(client) == :ready
    assert :sys.get_state(client).subscription_open_tasks == %{}
    assert DynamicSupervisor.count_children(subscription_supervisor).active == 0
  end

  test "malformed subscription acknowledgment fails only that subscription" do
    {client, transport, handle} = start_mock_subscription()
    id = handle.id

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/subscriptions/acknowledged",
      "params" => %{
        "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id},
        "notifications" => "not-an-object"
      }
    })

    assert {:error, {:invalid_acknowledgment, _reason}} =
             SubscriptionHandle.next(handle, 1_000)

    assert Client.status(client) == :ready
  end

  test "an acknowledgment delivered before transport open returns is preserved" do
    subscription_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    client =
      start_supervised!(
        {Client,
         transport: {MCP.Test.EagerSubscriptionTransport, []},
         subscription_supervisor: subscription_supervisor}
      )

    assert {:ok, handle} =
             Client.listen_subscriptions(
               client,
               %SubscriptionFilter{tools_list_changed: true},
               timeout: 1_000
             )

    assert {:ok, %{"method" => "notifications/subscriptions/acknowledged"}} =
             SubscriptionHandle.next(handle, 1_000)
  end

  test "an eager subscription protocol failure fails the open call" do
    subscription_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    client =
      start_supervised!(
        {Client,
         transport: {MCP.Test.EagerSubscriptionTransport, invalid_message?: true},
         subscription_supervisor: subscription_supervisor}
      )

    assert {:error, :notification_before_acknowledgment} =
             Client.listen_subscriptions(
               client,
               %SubscriptionFilter{tools_list_changed: true},
               timeout: 1_000
             )

    assert :sys.get_state(client).subscription_open_tasks == %{}
    assert DynamicSupervisor.count_children(subscription_supervisor).active == 0
  end

  test "subscription worker exit while opening fails the caller and cancels transport work" do
    subscription_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    client =
      start_supervised!(
        {Client,
         transport: {BlockingTransport, observer: self()},
         subscription_supervisor: subscription_supervisor}
      )

    open =
      Task.async(fn ->
        Client.listen_subscriptions(
          client,
          %SubscriptionFilter{tools_list_changed: true},
          timeout: 1_000
        )
      end)

    assert_receive {:transport_send_started, %{"method" => "subscriptions/listen"}}, 1_000
    [{_id, subscription}] = :sys.get_state(client).subscriptions |> Map.to_list()
    GenServer.stop(subscription.worker, :normal)

    assert {:error, {:subscription_worker_exit, :normal}} = Task.await(open, 1_000)
    assert :sys.get_state(client).subscription_open_tasks == %{}
  end

  test "subscription worker exit cannot crash the client after transport loss" do
    {client, transport, handle} = start_mock_subscription()
    client_ref = Process.monitor(client)

    GenServer.stop(transport, :normal)
    assert :ok = SubscriptionHandle.close(handle)
    _ = :sys.get_state(client)

    refute_receive {:DOWN, ^client_ref, :process, ^client, _reason}, 100
    assert Client.status(client) == :ready
  end

  test "malformed final subscription result fails only that subscription" do
    {client, transport, handle} = start_mock_subscription()
    id = handle.id

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/subscriptions/acknowledged",
      "params" => %{
        "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id},
        "notifications" => %{"toolsListChanged" => true}
      }
    })

    assert {:ok, _acknowledgment} = SubscriptionHandle.next(handle, 1_000)
    MockTransport.inject(transport, %{"jsonrpc" => "2.0", "id" => id, "result" => []})

    assert {:error, :invalid_subscription_result} =
             SubscriptionHandle.next(handle, 1_000)

    assert Client.status(client) == :ready
  end

  defp input_required(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "resultType" => "input_required",
        "inputRequests" => %{"input" => %{"method" => "elicitation/create", "params" => %{}}},
        "requestState" => "continuation"
      }
    }
  end

  defp start_mock_subscription do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    client =
      start_supervised!(
        {Client, transport: {MockTransport, []}, subscription_supervisor: supervisor}
      )

    transport = Client.transport(client)

    {:ok, handle} =
      Client.listen_subscriptions(
        client,
        %SubscriptionFilter{tools_list_changed: true}
      )

    {client, transport, handle}
  end

  defp await_request(transport, count \\ 1) do
    case MockTransport.await_sent(transport, count) do
      {:ok, messages} -> Enum.at(messages, count - 1)
      {:error, :timeout} -> flunk("request was not sent")
    end
  end
end
