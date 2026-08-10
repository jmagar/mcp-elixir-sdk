defmodule MCP.Server.SubscriptionWorker do
  @moduledoc false

  use GenServer

  alias MCP.Protocol.Messages.Subscriptions.AcknowledgedParams
  alias MCP.Protocol.Methods
  alias MCP.Protocol.Types.SubscriptionFilter
  alias MCP.Server.SubscriptionRegistry

  @default_queue_limit 256
  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  defstruct [
    :id,
    :registry,
    :registry_key,
    :endpoint,
    :owner,
    :owner_ref,
    :requested,
    :honored,
    :acknowledgment,
    :waiter,
    notify_owner?: false,
    queue: :queue.new(),
    queue_size: 0,
    queue_limit: @default_queue_limit,
    registered?: false,
    terminal?: false
  ]

  @type request_id :: String.t() | integer()

  @spec start(
          GenServer.server(),
          atom() | pid(),
          term(),
          request_id(),
          pid(),
          SubscriptionFilter.t(),
          SubscriptionFilter.t(),
          keyword()
        ) :: DynamicSupervisor.on_start_child() | {:error, term()}
  def start(supervisor, registry, endpoint, id, owner, requested, honored, opts \\ []) do
    queue_limit = Keyword.get(opts, :queue_limit, @default_queue_limit)
    notify_owner? = Keyword.get(opts, :notify_owner, false)

    with {:ok, registry_name} <- SubscriptionRegistry.name(registry) do
      cond do
        not (is_integer(queue_limit) and queue_limit > 0) ->
          {:error, {:invalid_queue_limit, queue_limit}}

        not subset?(honored, requested) ->
          {:error, :honored_filter_not_subset}

        true ->
          args = {
            registry_name,
            endpoint,
            id,
            owner,
            requested,
            honored,
            queue_limit,
            notify_owner?
          }

          DynamicSupervisor.start_child(supervisor, {__MODULE__, args})
      end
    end
  end

  @spec publish(pid(), String.t(), map() | nil) ::
          :ok | {:error, :invalid_notification_params}
  def publish(worker, method, params) do
    if valid_notification_params?(params) do
      GenServer.cast(worker, {:publish, method, params})
    else
      {:error, :invalid_notification_params}
    end
  end

  @spec complete(pid()) :: :ok
  def complete(worker) do
    GenServer.cast(worker, :complete)
  end

  @spec next(pid(), timeout()) :: {:ok, map()} | {:error, term()}
  def next(worker, timeout \\ 5_000) do
    GenServer.call(worker, {:next, timeout}, :infinity)
  catch
    :exit, {:noproc, _call} -> {:error, :closed}
    :exit, reason -> {:error, reason}
  end

  @spec start_link(tuple()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
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
  def init({registry, endpoint, id, owner, requested, honored, queue_limit, notify_owner?}) do
    registry_key = {:mcp_subscriptions, endpoint}

    state = %__MODULE__{
      id: id,
      registry: registry,
      registry_key: registry_key,
      endpoint: endpoint,
      owner: owner,
      owner_ref: Process.monitor(owner),
      requested: requested,
      honored: honored,
      acknowledgment: acknowledgment(id, honored),
      queue_limit: queue_limit,
      notify_owner?: notify_owner?
    }

    case Registry.register(state.registry, state.registry_key, %{honored: state.honored}) do
      {:ok, _value} ->
        notify_owner(state)
        {:ok, %{state | registered?: true}}

      {:error, {:already_registered, pid}} ->
        {:stop, {:registry_conflict, pid}}
    end
  end

  @impl true
  def handle_call({:next, _timeout}, _from, %__MODULE__{acknowledgment: acknowledgment} = state)
      when not is_nil(acknowledgment) do
    {:reply, {:ok, acknowledgment}, %{state | acknowledgment: nil}}
  end

  def handle_call({:next, timeout}, from, %__MODULE__{queue_size: 0, waiter: nil} = state) do
    {:noreply, %{state | waiter: new_waiter(from, timeout)}}
  end

  def handle_call({:next, _timeout}, _from, %__MODULE__{queue_size: 0} = state) do
    {:reply, {:error, :concurrent_next}, state}
  end

  def handle_call({:next, _timeout}, _from, %__MODULE__{} = state) do
    {{:value, notification}, queue} = :queue.out(state.queue)
    next_state = %{state | queue: queue, queue_size: state.queue_size - 1}

    case notification do
      {:mcp_subscription_terminal, response} ->
        {:stop, :normal, {:ok, response}, next_state}

      notification ->
        {:reply, {:ok, notification}, next_state}
    end
  end

  @impl true
  def handle_cast({:publish, method, params}, %__MODULE__{waiter: waiter} = state)
      when not is_nil(waiter) do
    complete_waiter(waiter, {:ok, notification(state.id, method, params)})
    {:noreply, %{state | waiter: nil}}
  end

  def handle_cast({:publish, _method, _params}, %__MODULE__{terminal?: true} = state),
    do: {:noreply, state}

  def handle_cast({:publish, method, params}, %__MODULE__{} = state)
      when state.queue_size < state.queue_limit and not state.terminal? do
    notification = notification(state.id, method, params)
    notify_owner(state)

    {:noreply,
     %{
       state
       | queue: :queue.in(notification, state.queue),
         queue_size: state.queue_size + 1
     }}
  end

  def handle_cast({:publish, _method, _params}, %__MODULE__{} = state) do
    {:stop, :queue_overflow, state}
  end

  def handle_cast(:complete, %__MODULE__{terminal?: true} = state), do: {:noreply, state}

  def handle_cast(:complete, %__MODULE__{waiter: waiter} = state) when not is_nil(waiter) do
    complete_waiter(waiter, {:ok, completion_response(state.id)})
    {:stop, :normal, %{state | waiter: nil, terminal?: true}}
  end

  def handle_cast(:complete, %__MODULE__{} = state) when state.queue_size < state.queue_limit do
    terminal = {:mcp_subscription_terminal, completion_response(state.id)}
    notify_owner(state)

    {:noreply,
     %{
       state
       | queue: :queue.in(terminal, state.queue),
         queue_size: state.queue_size + 1,
         terminal?: true
     }}
  end

  def handle_cast(:complete, %__MODULE__{} = state), do: {:stop, :queue_overflow, state}

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

  @impl true
  def terminate(_reason, %__MODULE__{registered?: true} = state) do
    Registry.unregister(state.registry, state.registry_key)
    :ok
  end

  def terminate(_reason, %__MODULE__{}), do: :ok

  defp acknowledgment(id, honored) do
    params = %AcknowledgedParams{
      notifications: honored,
      meta: %{@subscription_id_key => id}
    }

    %{
      "jsonrpc" => "2.0",
      "method" => Methods.subscriptions_acknowledged(),
      "params" => AcknowledgedParams.to_map(params)
    }
  end

  defp notification(id, method, params) do
    params = params || %{}
    meta = Map.get(params, "_meta", %{})
    params = Map.put(params, "_meta", Map.put(meta, @subscription_id_key, id))

    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  defp completion_response(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "_meta" => %{@subscription_id_key => id},
        "resultType" => "complete"
      }
    }
  end

  defp subset?(%SubscriptionFilter{} = honored, %SubscriptionFilter{} = requested) do
    boolean_subset?(honored.tools_list_changed, requested.tools_list_changed) and
      boolean_subset?(honored.prompts_list_changed, requested.prompts_list_changed) and
      boolean_subset?(honored.resources_list_changed, requested.resources_list_changed) and
      Enum.all?(honored.resource_subscriptions, &(&1 in requested.resource_subscriptions))
  end

  defp boolean_subset?(false, _requested), do: true
  defp boolean_subset?(true, true), do: true
  defp boolean_subset?(true, false), do: false

  defp valid_notification_params?(nil), do: true

  defp valid_notification_params?(params) when is_map(params) do
    case Map.fetch(params, "_meta") do
      {:ok, meta} -> is_map(meta)
      :error -> true
    end
  end

  defp valid_notification_params?(_params), do: false

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

  defp notify_owner(%__MODULE__{notify_owner?: true} = state) do
    send(state.owner, {:mcp_subscription_ready, state.id, self()})
  end

  defp notify_owner(%__MODULE__{}), do: :ok
end
