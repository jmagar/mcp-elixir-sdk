defmodule MCP.Client.SubscriptionWorkerTest do
  use ExUnit.Case, async: true

  alias MCP.Client.SubscriptionHandle
  alias MCP.Client.SubscriptionWorker

  setup do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    %{supervisor: supervisor}
  end

  test "delivers queued events in FIFO order", %{supervisor: supervisor} do
    {:ok, worker} = SubscriptionWorker.start(supervisor, "sub-1", self(), queue_limit: 2)
    handle = SubscriptionHandle.new("sub-1", worker)

    SubscriptionWorker.enqueue(worker, %{method: "first"})
    SubscriptionWorker.enqueue(worker, %{method: "second"})

    assert SubscriptionHandle.next(handle, 1_000) == {:ok, %{method: "first"}}
    assert SubscriptionHandle.next(handle, 1_000) == {:ok, %{method: "second"}}
  end

  test "a timed-out read does not consume the next event", %{supervisor: supervisor} do
    {:ok, worker} = SubscriptionWorker.start(supervisor, "timed", self())
    handle = SubscriptionHandle.new("timed", worker)

    assert SubscriptionHandle.next(handle, 1) == {:error, :timeout}

    SubscriptionWorker.enqueue(worker, :after_timeout)

    assert SubscriptionHandle.next(handle, 1_000) == {:ok, :after_timeout}
  end

  test "an invalid timeout is rejected without terminating the subscription", %{
    supervisor: supervisor
  } do
    {:ok, worker} = SubscriptionWorker.start(supervisor, "invalid-timeout", self())
    handle = SubscriptionHandle.new("invalid-timeout", worker)

    assert SubscriptionHandle.next(handle, -1) == {:error, {:invalid_timeout, -1}}

    assert SubscriptionHandle.next(handle, :eventually) ==
             {:error, {:invalid_timeout, :eventually}}

    SubscriptionWorker.enqueue(worker, :still_available)
    assert SubscriptionHandle.next(handle, 1_000) == {:ok, :still_available}
  end

  test "close/1 is idempotent and reports a closed handle", %{supervisor: supervisor} do
    {:ok, worker} = SubscriptionWorker.start(supervisor, 42, self())
    handle = SubscriptionHandle.new(42, worker)

    assert SubscriptionHandle.close(handle) == :ok
    assert SubscriptionHandle.close(handle) == :ok
    assert SubscriptionHandle.next(handle, 0) == {:error, :closed}
  end

  @tag capture_log: true
  test "queue overflow is observable and does not terminate a sibling", %{supervisor: supervisor} do
    {:ok, overflowing} =
      SubscriptionWorker.start(supervisor, "overflow", self(), queue_limit: 2)

    {:ok, sibling} = SubscriptionWorker.start(supervisor, "sibling", self(), queue_limit: 2)

    overflowing_handle = SubscriptionHandle.new("overflow", overflowing)
    sibling_handle = SubscriptionHandle.new("sibling", sibling)

    SubscriptionWorker.enqueue(overflowing, :one)
    SubscriptionWorker.enqueue(overflowing, :two)
    SubscriptionWorker.enqueue(overflowing, :three)
    SubscriptionWorker.enqueue(sibling, :still_available)

    assert SubscriptionHandle.next(overflowing_handle, 1_000) == {:error, :queue_overflow}
    assert SubscriptionHandle.next(sibling_handle, 1_000) == {:ok, :still_available}
  end

  test "terminates normally when its owner exits", %{supervisor: supervisor} do
    owner =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :finish -> :ok
           end
         end}
      )

    {:ok, worker} = SubscriptionWorker.start(supervisor, "owned", owner)
    ref = Process.monitor(worker)

    send(owner, :finish)

    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 1_000
  end

  test "rejects non-positive queue limits", %{supervisor: supervisor} do
    assert SubscriptionWorker.start(supervisor, "bad", self(), queue_limit: 0) ==
             {:error, {:invalid_queue_limit, 0}}
  end
end
