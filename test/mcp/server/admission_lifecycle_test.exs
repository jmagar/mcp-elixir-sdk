defmodule MCP.Server.AdmissionLifecycleTest do
  use ExUnit.Case, async: false

  alias MCP.Protocol.Types.SubscriptionFilter
  alias MCP.Server.{CallbackExecutor, SubscriptionAdmission, SubscriptionWorker}

  test "callback limiter never loses a reservation at zero transitions" do
    limiter = CallbackExecutor.new_limiter(1)
    counters = :atomics.new(2, signed: false)

    config = %{
      handler_callback_limiter: limiter,
      handler_callback_supervisor: MCP.Server.CallbackTaskSupervisor,
      handler_callback_timeout: 5_000
    }

    1..2_000
    |> Task.async_stream(
      fn _iteration ->
        CallbackExecutor.run(config, fn ->
          active = :atomics.add_get(counters, 1, 1)
          update_max(counters, active)
          Process.sleep(1)
          :atomics.sub(counters, 1, 1)
          :ok
        end)
      end,
      max_concurrency: 32,
      timeout: 10_000
    )
    |> Stream.run()

    assert :atomics.get(counters, 2) == 1
  end

  test "retires an idle callback limiter" do
    limiter = CallbackExecutor.new_limiter(1)

    config = %{
      handler_callback_limiter: limiter,
      handler_callback_supervisor: MCP.Server.CallbackTaskSupervisor,
      handler_callback_timeout: 1_000
    }

    assert {:ok, :done} = CallbackExecutor.run(config, fn -> :done end)
    assert [{_, 0}] = :ets.lookup(MCP.Server.CallbackExecutor, limiter.key)

    assert :ok = CallbackExecutor.retire_limiter(limiter)
    assert [] = :ets.lookup(MCP.Server.CallbackExecutor, limiter.key)
  end

  test "subscription admission restart cleanly terminates dependent consumer workers" do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    registry = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :duplicate, name: registry})
    filter = %SubscriptionFilter{tools_list_changed: true}

    {:ok, worker} =
      SubscriptionWorker.start(
        supervisor,
        registry,
        :restart_test,
        "restart-test",
        self(),
        filter,
        filter
      )

    worker_ref = Process.monitor(worker)
    admission = SubscriptionAdmission.owner(registry)
    Process.exit(admission, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 2_000

    assert_eventually(fn ->
      Registry.lookup(registry, {:mcp_subscriptions, :restart_test}) == []
    end)

    assert_eventually(fn -> is_pid(SubscriptionAdmission.owner(registry)) end)
  end

  test "callback admission restart also restarts its dependent task supervisor" do
    old_supervisor = Process.whereis(MCP.Server.CallbackTaskSupervisor)
    ref = Process.monitor(old_supervisor)
    Process.exit(Process.whereis(CallbackExecutor), :kill)

    assert_receive {:DOWN, ^ref, :process, ^old_supervisor, _reason}, 2_000

    assert_eventually(fn ->
      case Process.whereis(MCP.Server.CallbackTaskSupervisor) do
        pid when is_pid(pid) -> pid != old_supervisor
        _ -> false
      end
    end)
  end

  defp assert_eventually(assertion, attempts \\ 100)
  defp assert_eventually(assertion, 0), do: assert(assertion.())

  defp assert_eventually(assertion, attempts) do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(assertion, attempts - 1)
    end
  end

  defp update_max(counters, active) do
    current = :atomics.get(counters, 2)

    cond do
      active <= current -> :ok
      :atomics.compare_exchange(counters, 2, current, active) == current -> :ok
      true -> update_max(counters, active)
    end
  end
end
