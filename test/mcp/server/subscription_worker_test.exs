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
  test "overflow removes only that registration and leaves siblings usable", context do
    filter = %SubscriptionFilter{tools_list_changed: true}

    {:ok, overflowing} =
      start_worker(context, "overflow", filter, filter, queue_limit: 2)

    {:ok, sibling} = start_worker(context, "sibling", filter, filter, queue_limit: 2)
    _ = :sys.get_state(overflowing)
    _ = :sys.get_state(sibling)

    ref = Process.monitor(overflowing)
    :ok = :sys.suspend(overflowing)

    for sequence <- 1..3 do
      SubscriptionWorker.publish(
        overflowing,
        Methods.tools_list_changed(),
        %{"sequence" => sequence}
      )
    end

    :ok = :sys.resume(overflowing)

    assert_receive {:DOWN, ^ref, :process, ^overflowing, :queue_overflow}, 5_000
    assert Registry.lookup(context.registry, {:mcp_subscriptions, :endpoint}) |> length() == 1
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
