defmodule MCP.Server.SubscriptionAdmission do
  @moduledoc false
  use GenServer

  @registry MCP.Server.SubscriptionAdmission.Registry
  @supervisor MCP.Server.SubscriptionAdmission.Supervisor

  def start_link(registry), do: GenServer.start_link(__MODULE__, registry, name: via(registry))

  def owner(registry) do
    case Registry.lookup(@registry, registry) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def register(worker, registry, endpoint, id_bytes, count_limit, byte_limit, endpoint_limit) do
    with {:ok, admission} <- ensure(registry) do
      GenServer.call(
        admission,
        {:register, worker, endpoint, id_bytes, count_limit, byte_limit, endpoint_limit}
      )
    end
  catch
    :exit, _ -> {:error, :closed}
  end

  def unregister(admission, worker), do: call_or_ignore(admission, {:unregister, worker})

  def remember(worker, admission),
    do: :persistent_term.put({__MODULE__, :worker, worker}, admission)

  def forget(worker), do: :persistent_term.erase({__MODULE__, :worker, worker})

  def reserve(worker, bytes),
    do: reserve(:persistent_term.get({__MODULE__, :worker, worker}, nil), worker, bytes)

  def reserve(admission, worker, bytes), do: reserve_known(admission, worker, bytes)

  def reserve_read(worker) do
    with admission when not is_nil(admission) <-
           :persistent_term.get({__MODULE__, :worker, worker}, nil),
         table when not is_nil(table) <- table(admission) do
      case :ets.update_counter(table, worker, {8, 1}) do
        1 ->
          :ok

        _ ->
          :ets.update_counter(table, worker, {8, -1, 0, 0})
          {:error, :concurrent_next}
      end
    else
      _ -> {:error, :closed}
    end
  rescue
    ArgumentError -> {:error, :closed}
  end

  def release_read(worker) do
    case :persistent_term.get({__MODULE__, :worker, worker}, nil) do
      nil ->
        :ok

      admission ->
        :ets.update_counter(table(admission), worker, {8, -1, 0, 0})
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  def reserve_prepared(admission, worker, base_bytes) do
    with table when not is_nil(table) <- table(admission),
         [{^worker, _count, _bytes, _count_limit, _byte_limit, _endpoint, id_bytes, _reads}] <-
           :ets.lookup(table, worker) do
      bytes = base_bytes + id_bytes

      case reserve_known(admission, worker, bytes),
        do: (
          :ok -> {:ok, bytes}
          error -> error
        )
    else
      _ -> {:error, :closed}
    end
  rescue
    ArgumentError -> {:error, :closed}
  end

  def reserve_prepared(worker, base_bytes) do
    reserve_prepared(:persistent_term.get({__MODULE__, :worker, worker}, nil), worker, base_bytes)
  end

  def release(admission, worker, bytes) do
    _ = :ets.update_counter(table(admission), worker, [{2, -1, 0, 0}, {3, -bytes, 0, 0}])
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ensure(registry) do
    case Registry.lookup(@registry, registry) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, registry}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp via(registry), do: {:via, Registry, {@registry, registry}}
  defp table(admission), do: :persistent_term.get({__MODULE__, admission}, nil)

  @impl true
  def init(registry) do
    table = :ets.new(__MODULE__, [:public, :set, read_concurrency: true])
    :persistent_term.put({__MODULE__, self()}, table)
    {:ok, %{registry: registry, table: table, workers: %{}, refs: %{}}}
  end

  @impl true
  def handle_call(
        {:register, worker, endpoint, id_bytes, count_limit, byte_limit, endpoint_limit},
        _from,
        state
      ) do
    active = endpoint_count(state.table, endpoint)

    if active >= endpoint_limit do
      {:reply, {:error, :endpoint_subscription_limit}, state}
    else
      :ets.insert(state.table, {{:endpoint, endpoint}, active + 1})
      :ets.insert(state.table, {worker, 0, 0, count_limit, byte_limit, endpoint, id_bytes, 0})
      ref = Process.monitor(worker)

      next = %{
        state
        | workers: Map.put(state.workers, worker, ref),
          refs: Map.put(state.refs, ref, worker)
      }

      {:reply, {:ok, self()}, next}
    end
  end

  def handle_call({:unregister, worker}, _from, state),
    do: {:reply, :ok, remove_worker(state, worker, true)}

  @impl true
  def handle_info({:DOWN, ref, :process, worker, _}, state) do
    if state.refs[ref] == worker,
      do: {:noreply, remove_worker(state, worker, false)},
      else: {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state), do: :persistent_term.erase({__MODULE__, self()})

  defp remove_worker(state, worker, demonitor?) do
    case :ets.take(state.table, worker) do
      [{^worker, _, _, _, _, endpoint, _, _}] -> decrement_endpoint(state.table, endpoint)
      [] -> :ok
    end

    case Map.pop(state.workers, worker) do
      {nil, _} ->
        state

      {ref, workers} ->
        if demonitor?, do: Process.demonitor(ref, [:flush])
        %{state | workers: workers, refs: Map.delete(state.refs, ref)}
    end
  end

  defp reserve_known(admission, worker, bytes) do
    table = table(admission)

    with table when not is_nil(table) <- table,
         [{^worker, _, _, count_limit, byte_limit, _, _, _}] <- :ets.lookup(table, worker) do
      count = :ets.update_counter(table, worker, {2, 1})

      cond do
        count > count_limit ->
          :ets.update_counter(table, worker, {2, -1, 0, 0})
          {:error, :queue_overflow}

        :ets.update_counter(table, worker, {3, bytes}) > byte_limit ->
          :ets.update_counter(table, worker, [{2, -1, 0, 0}, {3, -bytes, 0, 0}])
          {:error, :queue_overflow}

        true ->
          :ok
      end
    else
      _ -> {:error, :closed}
    end
  rescue
    ArgumentError -> {:error, :closed}
  end

  defp endpoint_count(table, endpoint) do
    case :ets.lookup(table, {:endpoint, endpoint}) do
      [{{:endpoint, ^endpoint}, count}] -> count
      [] -> 0
    end
  end

  defp decrement_endpoint(table, endpoint) do
    case endpoint_count(table, endpoint) do
      count when count > 1 -> :ets.insert(table, {{:endpoint, endpoint}, count - 1})
      _ -> :ets.delete(table, {:endpoint, endpoint})
    end
  end

  defp call_or_ignore(admission, message) do
    GenServer.call(admission, message)
  catch
    :exit, _ -> :ok
  end
end
