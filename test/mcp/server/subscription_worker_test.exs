defmodule MCP.Server.SubscriptionWorkerTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Methods
  alias MCP.Protocol.Types.SubscriptionFilter
  alias MCP.Server.SubscriptionPublisher
  alias MCP.Server.SubscriptionWorker

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  setup do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    registry = start_registry()
    %{registry: registry, supervisor: supervisor}
  end

  test "acknowledges before delivering filtered and correlated notifications", context do
    requested = %SubscriptionFilter{
      tools_list_changed: true,
      prompts_list_changed: true,
      resource_subscriptions: ["file:///guide.md"]
    }

    honored = %SubscriptionFilter{
      tools_list_changed: true,
      resource_subscriptions: ["file:///guide.md"]
    }

    {:ok, worker} = start_worker(context, "sub-1", requested, honored)
    _ = :sys.get_state(worker)

    assert :ok =
             SubscriptionPublisher.publish(
               context.registry,
               :endpoint,
               Methods.prompts_list_changed(),
               %{}
             )

    assert :ok =
             SubscriptionPublisher.publish(
               context.registry,
               :endpoint,
               Methods.tools_list_changed(),
               %{"_meta" => %{"com.example/trace" => "abc"}}
             )

    assert {:ok, acknowledgment} = SubscriptionWorker.next(worker, 1_000)
    assert acknowledgment["method"] == Methods.subscriptions_acknowledged()

    assert acknowledgment["params"]["notifications"] == %{
             "toolsListChanged" => true,
             "resourceSubscriptions" => ["file:///guide.md"]
           }

    assert acknowledgment["params"]["_meta"][@subscription_id_key] == "sub-1"

    assert {:ok, notification} = SubscriptionWorker.next(worker, 1_000)
    assert notification["method"] == Methods.tools_list_changed()
    assert notification["params"]["_meta"][@subscription_id_key] == "sub-1"
    assert notification["params"]["_meta"]["com.example/trace"] == "abc"
  end

  test "filters resource updates by exact URI", context do
    filter = %SubscriptionFilter{resource_subscriptions: ["file:///guide.md"]}
    {:ok, worker} = start_worker(context, 9, filter, filter)
    _ = :sys.get_state(worker)

    :ok =
      SubscriptionPublisher.publish(
        Process.whereis(context.registry),
        :endpoint,
        Methods.resources_updated(),
        %{"uri" => "file:///other.md"}
      )

    :ok =
      SubscriptionPublisher.publish(
        Process.whereis(context.registry),
        :endpoint,
        Methods.resources_updated(),
        %{"uri" => "file:///guide.md"}
      )

    assert {:ok, _acknowledgment} = SubscriptionWorker.next(worker, 1_000)
    assert {:ok, notification} = SubscriptionWorker.next(worker, 1_000)
    assert notification["params"]["uri"] == "file:///guide.md"
  end

  test "a timed-out read does not consume the next notification", context do
    filter = %SubscriptionFilter{tools_list_changed: true}
    {:ok, worker} = start_worker(context, "timed", filter, filter)

    assert {:ok, _acknowledgment} = SubscriptionWorker.next(worker, 1_000)
    assert SubscriptionWorker.next(worker, 1) == {:error, :timeout}

    SubscriptionWorker.publish(worker, Methods.tools_list_changed(), %{})

    assert {:ok, notification} = SubscriptionWorker.next(worker, 1_000)
    assert notification["method"] == Methods.tools_list_changed()
  end

  test "rejects an honored filter that is not a subset of the request", context do
    requested = %SubscriptionFilter{tools_list_changed: true}
    honored = %SubscriptionFilter{prompts_list_changed: true}

    assert SubscriptionWorker.start(
             context.supervisor,
             context.registry,
             :endpoint,
             "invalid",
             self(),
             requested,
             honored
           ) == {:error, :honored_filter_not_subset}
  end

  @tag capture_log: true
  test "mailbox admission rejects overflow without killing that registration", context do
    filter = %SubscriptionFilter{tools_list_changed: true}

    {:ok, overflowing} =
      start_worker(context, "overflow", filter, filter, queue_limit: 2)

    {:ok, sibling} = start_worker(context, "sibling", filter, filter, queue_limit: 2)
    _ = :sys.get_state(overflowing)
    _ = :sys.get_state(sibling)

    :ok = :sys.suspend(overflowing)

    assert :ok =
             SubscriptionWorker.publish(
               overflowing,
               Methods.tools_list_changed(),
               %{"sequence" => 1}
             )

    assert :ok =
             SubscriptionWorker.publish(
               overflowing,
               Methods.tools_list_changed(),
               %{"sequence" => 2}
             )

    assert {:error, :queue_overflow} =
             SubscriptionWorker.publish(
               overflowing,
               Methods.tools_list_changed(),
               %{"sequence" => 3}
             )

    assert {:message_queue_len, 2} = Process.info(overflowing, :message_queue_len)

    :ok = :sys.resume(overflowing)

    assert {:ok, _acknowledgment} = SubscriptionWorker.next(overflowing, 1_000)
    assert {:ok, first} = SubscriptionWorker.next(overflowing, 1_000)
    assert {:ok, second} = SubscriptionWorker.next(overflowing, 1_000)
    assert first["params"]["sequence"] == 1
    assert second["params"]["sequence"] == 2
    assert Process.alive?(overflowing)
    assert Registry.lookup(context.registry, {:mcp_subscriptions, :endpoint}) |> length() == 2
    assert {:ok, acknowledgment} = SubscriptionWorker.next(sibling, 1_000)
    assert acknowledgment["params"]["_meta"][@subscription_id_key] == "sibling"
  end

  test "owner exit removes the worker registration", context do
    owner =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :finish -> :ok
           end
         end}
      )

    filter = %SubscriptionFilter{tools_list_changed: true}

    {:ok, worker} =
      SubscriptionWorker.start(
        context.supervisor,
        Process.whereis(context.registry),
        :endpoint,
        "owned",
        owner,
        filter,
        filter
      )

    _ = :sys.get_state(worker)
    ref = Process.monitor(worker)

    send(owner, :finish)

    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 1_000
    assert Registry.lookup(context.registry, {:mcp_subscriptions, :endpoint}) == []
  end

  test "invalid registries fail before start reports success", context do
    filter = %SubscriptionFilter{tools_list_changed: true}

    assert {:error, :invalid_registry} =
             SubscriptionWorker.start(
               context.supervisor,
               :not_a_registry,
               :endpoint,
               "invalid-registry",
               self(),
               filter,
               filter
             )

    assert SubscriptionPublisher.publish(
             :not_a_registry,
             :endpoint,
             Methods.tools_list_changed(),
             %{}
           ) == {:error, :invalid_registry}
  end

  test "invalid notification metadata is rejected before fanout", context do
    filter = %SubscriptionFilter{tools_list_changed: true}
    {:ok, worker} = start_worker(context, "still-alive", filter, filter)
    assert {:ok, _acknowledgment} = SubscriptionWorker.next(worker, 1_000)

    assert {:error, :invalid_notification_params} =
             SubscriptionPublisher.publish(
               context.registry,
               :endpoint,
               Methods.tools_list_changed(),
               %{"_meta" => nil}
             )

    assert Process.alive?(worker)

    assert :ok =
             SubscriptionPublisher.publish(
               context.registry,
               :endpoint,
               Methods.tools_list_changed(),
               %{}
             )

    assert {:ok, _notification} = SubscriptionWorker.next(worker, 1_000)
  end

  test "saturated subscribers do not suppress healthy fanout", context do
    filter = %SubscriptionFilter{tools_list_changed: true}
    {:ok, saturated} = start_worker(context, "saturated", filter, filter, queue_limit: 1)
    {:ok, healthy} = start_worker(context, "healthy", filter, filter, queue_limit: 2)
    assert {:ok, _} = SubscriptionWorker.next(saturated, 1_000)
    assert {:ok, _} = SubscriptionWorker.next(healthy, 1_000)

    assert :ok = SubscriptionWorker.publish(saturated, Methods.tools_list_changed(), %{})

    assert {:error, :queue_overflow} =
             SubscriptionPublisher.publish(
               context.registry,
               :endpoint,
               Methods.tools_list_changed(),
               %{"sequence" => 2}
             )

    assert {:ok, notification} = SubscriptionWorker.next(healthy, 1_000)
    assert notification["params"]["sequence"] == 2
  end

  test "completion and encoded bytes share the admission boundary", context do
    filter = %SubscriptionFilter{tools_list_changed: true}

    {:ok, worker} =
      start_worker(context, "bounded", filter, filter,
        queue_limit: 1,
        queue_byte_limit: 128
      )

    assert {:ok, _} = SubscriptionWorker.next(worker, 1_000)
    :ok = :sys.suspend(worker)

    assert :ok = SubscriptionWorker.complete(worker)
    assert {:error, :queue_overflow} = SubscriptionWorker.complete(worker)

    assert {:error, :queue_overflow} =
             SubscriptionWorker.publish(
               worker,
               Methods.tools_list_changed(),
               %{"payload" => String.duplicate("x", 256)}
             )

    assert {:message_queue_len, 1} = Process.info(worker, :message_queue_len)
    :ok = :sys.resume(worker)
  end

  test "encoded byte admission rejects an oversized event before enqueue", context do
    filter = %SubscriptionFilter{tools_list_changed: true}

    {:ok, worker} =
      start_worker(context, "byte-bounded", filter, filter,
        queue_limit: 2,
        queue_byte_limit: 256
      )

    assert {:ok, _} = SubscriptionWorker.next(worker, 1_000)

    assert {:error, :queue_overflow} =
             SubscriptionWorker.publish(
               worker,
               Methods.tools_list_changed(),
               %{"payload" => String.duplicate("x", 512)}
             )

    assert {:message_queue_len, 0} = Process.info(worker, :message_queue_len)
  end

  test "byte admission charges the exact retained subscription identifier", context do
    filter = %SubscriptionFilter{tools_list_changed: true}
    long_id = String.duplicate("identifier", 80)

    {:ok, worker} =
      start_worker(context, long_id, filter, filter,
        queue_limit: 2,
        queue_byte_limit: 256
      )

    assert {:ok, _} = SubscriptionWorker.next(worker, 1_000)

    assert {:error, :queue_overflow} =
             SubscriptionWorker.publish(worker, Methods.tools_list_changed(), %{})

    assert {:message_queue_len, 0} = Process.info(worker, :message_queue_len)
  end

  test "read admission bounds concurrent next calls before the worker mailbox", context do
    filter = %SubscriptionFilter{tools_list_changed: true}
    {:ok, worker} = start_worker(context, "read-bounded", filter, filter)
    :ok = :sys.suspend(worker)

    pending = Task.async(fn -> SubscriptionWorker.next(worker, 1_000) end)

    assert_eventually(fn ->
      Process.info(worker, :message_queue_len) == {:message_queue_len, 1}
    end)

    assert {:error, :concurrent_next} = SubscriptionWorker.next(worker, 1_000)
    assert {:message_queue_len, 1} = Process.info(worker, :message_queue_len)

    :ok = :sys.resume(worker)
    assert {:ok, _acknowledgment} = Task.await(pending, 1_000)
  end

  test "endpoint admission caps active subscriptions", context do
    endpoint = {:endpoint, System.unique_integer([:positive])}
    filter = %SubscriptionFilter{tools_list_changed: true}

    assert {:ok, first} =
             SubscriptionWorker.start(
               context.supervisor,
               context.registry,
               endpoint,
               "first-capped",
               self(),
               filter,
               filter,
               endpoint_limit: 1
             )

    _ = :sys.get_state(first)

    assert {:error, :endpoint_subscription_limit} =
             SubscriptionWorker.start(
               context.supervisor,
               context.registry,
               endpoint,
               "second-capped",
               self(),
               filter,
               filter,
               endpoint_limit: 1
             )
  end

  test "endpoint admission is isolated by registry and removes empty counters", context do
    second_registry = start_registry()
    endpoint = {:isolated, System.unique_integer([:positive])}
    filter = %SubscriptionFilter{tools_list_changed: true}

    {:ok, first} =
      SubscriptionWorker.start(
        context.supervisor,
        context.registry,
        endpoint,
        "first-registry",
        self(),
        filter,
        filter,
        endpoint_limit: 1
      )

    {:ok, second} =
      SubscriptionWorker.start(
        context.supervisor,
        second_registry,
        endpoint,
        "second-registry",
        self(),
        filter,
        filter,
        endpoint_limit: 1
      )

    GenServer.stop(first)
    GenServer.stop(second)

    assert_eventually(fn ->
      Registry.lookup(context.registry, {:mcp_subscriptions, endpoint}) == [] and
        Registry.lookup(second_registry, {:mcp_subscriptions, endpoint}) == []
    end)
  end

  @tag capture_log: true
  test "registry conflicts are returned by start instead of crashing after success", context do
    unique_registry =
      Module.concat(__MODULE__, "UniqueRegistry#{System.unique_integer([:positive])}")

    start_supervised!({Registry, keys: :unique, name: unique_registry})
    filter = %SubscriptionFilter{tools_list_changed: true}

    assert {:ok, first} =
             SubscriptionWorker.start(
               context.supervisor,
               unique_registry,
               :same_endpoint,
               "first",
               self(),
               filter,
               filter
             )

    _ = :sys.get_state(first)

    assert {:error, {:registry_conflict, ^first}} =
             SubscriptionWorker.start(
               context.supervisor,
               unique_registry,
               :same_endpoint,
               "second",
               self(),
               filter,
               filter
             )
  end

  defp start_registry do
    registry = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :duplicate, name: registry})
    registry
  end

  defp assert_eventually(assertion, attempts \\ 50)
  defp assert_eventually(assertion, 0), do: assert(assertion.())

  defp assert_eventually(assertion, attempts) do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(assertion, attempts - 1)
    end
  end

  defp start_worker(context, id, requested, honored, opts \\ []) do
    SubscriptionWorker.start(
      context.supervisor,
      context.registry,
      :endpoint,
      id,
      self(),
      requested,
      honored,
      opts
    )
  end
end
