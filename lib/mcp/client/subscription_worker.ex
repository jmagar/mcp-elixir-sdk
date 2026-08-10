defmodule MCP.Client.SubscriptionWorker do
  @moduledoc false

  use GenServer

  @default_queue_limit 256

  defstruct [
    :id,
    :owner,
    :owner_ref,
    :waiter,
    terminal?: false,
    queue: :queue.new(),
    queue_size: 0,
    queue_limit: @default_queue_limit
  ]

  @type request_id :: String.t() | integer()

  @spec start(GenServer.server(), request_id(), pid(), keyword()) ::
          DynamicSupervisor.on_start_child() | {:error, {:invalid_queue_limit, term()}}
  def start(supervisor, id, owner, opts \\ []) do
    queue_limit = Keyword.get(opts, :queue_limit, @default_queue_limit)

    if is_integer(queue_limit) and queue_limit > 0 do
      DynamicSupervisor.start_child(supervisor, {__MODULE__, {id, owner, queue_limit}})
    else
      {:error, {:invalid_queue_limit, queue_limit}}
    end
  end

  @spec enqueue(pid(), term()) :: :ok | {:error, :queue_overflow | :closed}
  def enqueue(worker, event) do
    GenServer.call(worker, {:enqueue, event}, :infinity)
  catch
    :exit, {:noproc, _call} -> {:error, :closed}
    :exit, _reason -> {:error, :closed}
  end

  @spec complete(pid(), term()) :: :ok
  def complete(worker, result) do
    GenServer.cast(worker, {:complete, result})
  end

  @spec fail(pid(), term()) :: :ok
  def fail(worker, reason) do
    GenServer.cast(worker, {:fail, reason})
  end

  @spec next(pid(), timeout()) :: {:ok, term()} | {:error, term()}
  def next(worker, timeout \\ 5_000) do
    GenServer.call(worker, {:next, timeout}, :infinity)
  catch
    :exit, {:noproc, _call} -> {:error, :closed}
    :exit, reason -> {:error, reason}
  end

  @spec start_link({request_id(), pid(), pos_integer()}) :: GenServer.on_start()
  def start_link({id, owner, queue_limit}) do
    GenServer.start_link(__MODULE__, {id, owner, queue_limit})
  end

  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init({id, owner, queue_limit}) do
    state = %__MODULE__{
      id: id,
      owner: owner,
      owner_ref: Process.monitor(owner),
      queue_limit: queue_limit
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, event}, _from, %__MODULE__{waiter: waiter} = state)
      when not is_nil(waiter) do
    complete_waiter(waiter, {:ok, event})
    {:reply, :ok, %{state | waiter: nil}}
  end

  def handle_call({:enqueue, event}, _from, %__MODULE__{} = state)
      when state.queue_size < state.queue_limit and not state.terminal? do
    next_state = %{state | queue: :queue.in(event, state.queue), queue_size: state.queue_size + 1}
    {:reply, :ok, next_state}
  end

  def handle_call({:enqueue, _event}, _from, %__MODULE__{} = state) do
    failure = {:mcp_subscription_failure, :queue_overflow}

    next_state = %{
      state
      | queue: :queue.in(failure, :queue.new()),
        queue_size: 1,
        terminal?: true
    }

    {:reply, {:error, :queue_overflow}, next_state}
  end

  def handle_call({:next, timeout}, from, %__MODULE__{queue_size: 0, waiter: nil} = state) do
    {:noreply, %{state | waiter: new_waiter(from, timeout)}}
  end

  def handle_call({:next, _timeout}, _from, %__MODULE__{queue_size: 0} = state) do
    {:reply, {:error, :concurrent_next}, state}
  end

  def handle_call({:next, _timeout}, _from, %__MODULE__{} = state) do
    {{:value, event}, queue} = :queue.out(state.queue)
    next_state = %{state | queue: queue, queue_size: state.queue_size - 1}

    case event do
      {:mcp_subscription_terminal, result} -> {:stop, :normal, {:ok, result}, next_state}
      {:mcp_subscription_failure, reason} -> {:stop, :normal, {:error, reason}, next_state}
      event -> {:reply, {:ok, event}, next_state}
    end
  end

  def handle_call(:close, _from, %__MODULE__{} = state) do
    complete_waiter(state.waiter, {:error, :closed})
    {:stop, :normal, :ok, %{state | waiter: nil}}
  end

  @impl true
  def handle_cast({:complete, result}, %__MODULE__{waiter: waiter} = state)
      when not is_nil(waiter) do
    complete_waiter(waiter, {:ok, result})
    {:stop, :normal, %{state | waiter: nil, terminal?: true}}
  end

  def handle_cast({:complete, result}, %__MODULE__{} = state)
      when state.queue_size < state.queue_limit and not state.terminal? do
    terminal = {:mcp_subscription_terminal, result}

    {:noreply,
     %{
       state
       | queue: :queue.in(terminal, state.queue),
         queue_size: state.queue_size + 1,
         terminal?: true
     }}
  end

  def handle_cast({:complete, _result}, %__MODULE__{terminal?: true} = state),
    do: {:noreply, state}

  def handle_cast({:complete, _result}, %__MODULE__{} = state),
    do: {:stop, :queue_overflow, state}

  def handle_cast({:fail, reason}, %__MODULE__{waiter: waiter} = state)
      when not is_nil(waiter) do
    complete_waiter(state.waiter, {:error, reason})
    {:stop, :normal, %{state | waiter: nil, terminal?: true}}
  end

  def handle_cast({:fail, reason}, %__MODULE__{} = state) do
    failure = {:mcp_subscription_failure, reason}

    {:noreply,
     %{
       state
       | queue: :queue.in(failure, :queue.new()),
         queue_size: 1,
         terminal?: true
     }}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _reason}, %__MODULE__{} = state)
      when ref == state.owner_ref and owner == state.owner do
    complete_waiter(state.waiter, {:error, :closed})
    {:stop, :normal, %{state | waiter: nil}}
  end

  def handle_info({:next_timeout, token}, %__MODULE__{waiter: {_from, token, _timer}} = state) do
    complete_waiter(state.waiter, {:error, :timeout})
    {:noreply, %{state | waiter: nil}}
  end

  def handle_info({:next_timeout, _token}, state), do: {:noreply, state}

  defp new_waiter(from, :infinity), do: {from, make_ref(), nil}

  defp new_waiter(from, timeout) when is_integer(timeout) and timeout >= 0 do
    token = make_ref()
    {from, token, Process.send_after(self(), {:next_timeout, token}, timeout)}
  end

  defp complete_waiter(nil, _reply), do: :ok

  defp complete_waiter({from, _token, timer}, reply) do
    if timer, do: Process.cancel_timer(timer)
    GenServer.reply(from, reply)
  end
end
