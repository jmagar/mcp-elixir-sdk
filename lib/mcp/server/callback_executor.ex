defmodule MCP.Server.CallbackExecutor do
  @moduledoc false

  use GenServer

  @table __MODULE__

  @type result ::
          {:ok, term()}
          | {:failure, :error | :exit | :throw, term(), Exception.stacktrace()}
          | :timeout
          | :overloaded
          | {:unavailable, term()}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    @table = :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end

  @spec new_limiter(pos_integer()) :: %{key: pos_integer(), limit: pos_integer()}
  def new_limiter(limit) when is_integer(limit) and limit > 0 do
    %{key: System.unique_integer([:positive]), limit: limit}
  end

  @doc false
  @spec retire_limiter(%{key: pos_integer()}) :: :ok
  def retire_limiter(%{key: key}) when is_integer(key) do
    # A connection retires its limiter only from `terminate/2`, after its
    # serialized request loop has stopped accepting work. Deleting a zero row
    # here therefore cannot race a new acquisition for that configuration.
    _ = :ets.select_delete(@table, [{{key, 0}, [], [true]}])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec run(map(), (-> term())) :: result()
  def run(config, callback) when is_function(callback, 0) do
    with {:ok, %{key: key, limit: limit} = limiter}
         when is_integer(key) and is_integer(limit) and limit > 0 <-
           Map.fetch(config, :handler_callback_limiter),
         {:ok, supervisor} when is_pid(supervisor) or is_atom(supervisor) <-
           Map.fetch(config, :handler_callback_supervisor),
         {:ok, timeout} when is_integer(timeout) and timeout > 0 <-
           Map.fetch(config, :handler_callback_timeout) do
      run_limited(config, limiter, callback)
    else
      _invalid -> {:unavailable, :missing_callback_executor_configuration}
    end
  end

  defp run_limited(config, limiter, callback) do
    case acquire(limiter) do
      :ok ->
        try do
          run_supervised(config, callback)
        after
          release(limiter)
        end

      :overloaded ->
        :overloaded
    end
  end

  defp acquire(%{key: key, limit: limit}) do
    if :ets.update_counter(@table, key, {2, 1}, {key, 0}) <= limit do
      :ok
    else
      _ = :ets.update_counter(@table, key, {2, -1})
      :overloaded
    end
  rescue
    ArgumentError -> :overloaded
  end

  defp release(%{key: key}) do
    _ = :ets.update_counter(@table, key, {2, -1, 0, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp run_supervised(config, callback) do
    supervisor = Map.fetch!(config, :handler_callback_supervisor)
    timeout = Map.fetch!(config, :handler_callback_timeout)
    owner = self()

    task = Task.Supervisor.async_nolink(supervisor, fn -> invoke(callback) end)
    _watcher = spawn(fn -> watch_owner_and_task(owner, task.pid) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> outcome
      {:exit, reason} -> {:failure, :exit, reason, []}
      nil -> :timeout
    end
  catch
    :exit, reason -> {:unavailable, reason}
  end

  defp invoke(callback) do
    {:ok, callback.()}
  rescue
    exception -> {:failure, :error, exception, __STACKTRACE__}
  catch
    kind, reason -> {:failure, kind, reason, __STACKTRACE__}
  end

  defp watch_owner_and_task(owner, task_pid) do
    owner_ref = Process.monitor(owner)
    task_ref = Process.monitor(task_pid)

    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> Process.exit(task_pid, :kill)
      {:DOWN, ^task_ref, :process, ^task_pid, _reason} -> :ok
    end

    Process.demonitor(owner_ref, [:flush])
    Process.demonitor(task_ref, [:flush])
  end
end
