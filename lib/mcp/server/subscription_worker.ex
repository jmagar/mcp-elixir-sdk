defmodule MCP.Server.SubscriptionWorker do
  @moduledoc false

  use GenServer

  alias MCP.Protocol.Messages.Subscriptions.AcknowledgedParams
  alias MCP.Protocol.Methods
  alias MCP.Protocol.Types.SubscriptionFilter
  alias MCP.Server.SubscriptionAdmission
  alias MCP.Server.SubscriptionRegistry

  @default_queue_limit 256
  @default_queue_byte_limit 1_000_000
  @default_endpoint_limit 1_024
  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  defstruct [
    :id,
    :registry,
    :registry_key,
    :endpoint,
    :owner,
    :owner_ref,
    :admission,
    :admission_ref,
    :requested,
    :honored,
    :acknowledgment,
    :waiter,
    notify_owner?: false,
    queue: :queue.new(),
    queue_size: 0,
    queue_limit: @default_queue_limit,
    queue_byte_limit: @default_queue_byte_limit,
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
    queue_byte_limit = Keyword.get(opts, :queue_byte_limit, @default_queue_byte_limit)
    endpoint_limit = Keyword.get(opts, :endpoint_limit, @default_endpoint_limit)
    notify_owner? = Keyword.get(opts, :notify_owner, false)

    with {:ok, registry_name} <- SubscriptionRegistry.name(registry) do
      cond do
        not (is_integer(queue_limit) and queue_limit > 0) ->
          {:error, {:invalid_queue_limit, queue_limit}}

        not (is_integer(queue_byte_limit) and queue_byte_limit > 0) ->
          {:error, {:invalid_queue_byte_limit, queue_byte_limit}}

        not (is_integer(endpoint_limit) and endpoint_limit > 0) ->
          {:error, {:invalid_endpoint_limit, endpoint_limit}}

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
            queue_byte_limit,
            endpoint_limit,
            notify_owner?
          }

          DynamicSupervisor.start_child(supervisor, {__MODULE__, args})
      end
    end
  end

  @spec publish(pid(), String.t(), map() | nil) ::
          :ok | {:error, :invalid_notification_params | :queue_overflow | :closed}
  def publish(worker, method, params) do
    with {:ok, prepared} <- prepare(method, params) do
      publish_prepared(worker, prepared)
    end
  rescue
    Jason.EncodeError -> {:error, :invalid_notification_params}
    Protocol.UndefinedError -> {:error, :invalid_notification_params}
  end

  def prepare(method, params) do
    if valid_notification_params?(params) do
      base_bytes = encoded_notification_bytes(method, params)
      {:ok, {method, params, base_bytes}}
    else
      {:error, :invalid_notification_params}
    end
  rescue
    Jason.EncodeError -> {:error, :invalid_notification_params}
    Protocol.UndefinedError -> {:error, :invalid_notification_params}
  end

  def publish_prepared(worker, admission, {method, params, base_bytes}) do
    with {:ok, message_bytes} <-
           SubscriptionAdmission.reserve_prepared(admission, worker, base_bytes) do
      GenServer.cast(worker, {:publish, method, params, message_bytes})
      :ok
    end
  end

  def publish_prepared(worker, {method, params, base_bytes}) do
    with {:ok, bytes} <- SubscriptionAdmission.reserve_prepared(worker, base_bytes) do
      GenServer.cast(worker, {:publish, method, params, bytes})
      :ok
    end
  end

  @spec complete(pid()) :: :ok | {:error, :queue_overflow | :closed}
  def complete(worker) do
    with :ok <- SubscriptionAdmission.reserve(worker, 0) do
      GenServer.cast(worker, :complete)
      :ok
    end
  end

  @spec next(pid(), timeout()) :: {:ok, map()} | {:error, term()}
  def next(worker, timeout \\ 5_000) do
    with :ok <- SubscriptionAdmission.reserve_read(worker) do
      try do
        GenServer.call(worker, {:next, timeout}, call_timeout(timeout))
      after
        SubscriptionAdmission.release_read(worker)
      end
    end
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
  def init(
        {registry, endpoint, id, owner, requested, honored, queue_limit, queue_byte_limit,
         endpoint_limit, notify_owner?}
      ) do
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
      queue_byte_limit: queue_byte_limit,
      notify_owner?: notify_owner?
    }

    case SubscriptionAdmission.register(
           self(),
           registry,
           endpoint,
           encoded_id_bytes(id),
           queue_limit,
           queue_byte_limit,
           endpoint_limit
         ) do
      {:ok, admission_owner} ->
        registry_value = %{
          honored: state.honored,
          resource_subscription_set: MapSet.new(state.honored.resource_subscriptions),
          admission: admission_owner
        }

        case Registry.register(state.registry, state.registry_key, registry_value) do
          {:ok, _} ->
            SubscriptionAdmission.remember(self(), admission_owner)
            notify_owner(state)

            {:ok,
             %{
               state
               | registered?: true,
                 admission: admission_owner,
                 admission_ref: Process.monitor(admission_owner)
             }}

          {:error, {:already_registered, pid}} ->
            SubscriptionAdmission.unregister(admission_owner, self())
            {:stop, {:registry_conflict, pid}}
        end

      {:error, reason} ->
        {:stop, reason}
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
    {{:value, {notification, bytes}}, queue} = :queue.out(state.queue)
    SubscriptionAdmission.release(state.admission, self(), bytes)
    next_state = %{state | queue: queue, queue_size: state.queue_size - 1}

    case notification do
      {:mcp_subscription_terminal, response} ->
        {:stop, :normal, {:ok, response}, next_state}

      notification ->
        {:reply, {:ok, notification}, next_state}
    end
  end

  @impl true
  def handle_cast({:publish, method, params, bytes}, %__MODULE__{waiter: waiter} = state)
      when not is_nil(waiter) do
    SubscriptionAdmission.release(state.admission, self(), bytes)
    complete_waiter(waiter, {:ok, notification(state.id, method, params)})
    {:noreply, %{state | waiter: nil}}
  end

  def handle_cast({:publish, _method, _params, bytes}, %__MODULE__{terminal?: true} = state) do
    SubscriptionAdmission.release(state.admission, self(), bytes)
    {:noreply, state}
  end

  def handle_cast({:publish, method, params, bytes}, %__MODULE__{} = state)
      when state.queue_size < state.queue_limit and not state.terminal? do
    notification = notification(state.id, method, params)
    notify_owner(state)

    {:noreply,
     %{
       state
       | queue: :queue.in({notification, bytes}, state.queue),
         queue_size: state.queue_size + 1
     }}
  end

  def handle_cast({:publish, _method, _params, bytes}, %__MODULE__{} = state) do
    SubscriptionAdmission.release(state.admission, self(), bytes)
    {:noreply, state}
  end

  def handle_cast(:complete, %__MODULE__{terminal?: true} = state) do
    SubscriptionAdmission.release(state.admission, self(), 0)
    {:noreply, state}
  end

  def handle_cast(:complete, %__MODULE__{waiter: waiter} = state) when not is_nil(waiter) do
    SubscriptionAdmission.release(state.admission, self(), 0)
    complete_waiter(waiter, {:ok, completion_response(state.id)})
    {:stop, :normal, %{state | waiter: nil, terminal?: true}}
  end

  def handle_cast(:complete, %__MODULE__{} = state) when state.queue_size < state.queue_limit do
    terminal = {:mcp_subscription_terminal, completion_response(state.id)}
    notify_owner(state)

    {:noreply,
     %{
       state
       | queue: :queue.in({terminal, 0}, state.queue),
         queue_size: state.queue_size + 1,
         terminal?: true
     }}
  end

  def handle_cast(:complete, %__MODULE__{} = state) do
    SubscriptionAdmission.release(state.admission, self(), 0)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _reason}, %__MODULE__{} = state)
      when ref == state.owner_ref and owner == state.owner do
    complete_waiter(state.waiter, {:error, :closed})
    {:stop, :normal, %{state | waiter: nil}}
  end

  def handle_info(
        {:DOWN, ref, :process, _owner, _reason},
        %__MODULE__{admission_ref: ref} = state
      ) do
    complete_waiter(state.waiter, {:error, :closed})
    {:stop, :normal, %{state | waiter: nil, registered?: false}}
  end

  def handle_info({:next_timeout, token}, %__MODULE__{waiter: {_from, token, _timer}} = state) do
    complete_waiter(state.waiter, {:error, :timeout})
    {:noreply, %{state | waiter: nil}}
  end

  def handle_info({:next_timeout, _token}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %__MODULE__{registered?: true} = state) do
    SubscriptionAdmission.unregister(state.admission, self())
    SubscriptionAdmission.forget(self())
    Registry.unregister(state.registry, state.registry_key)
    :ok
  end

  def terminate(_reason, state) do
    if state.admission, do: SubscriptionAdmission.unregister(state.admission, self())
    SubscriptionAdmission.forget(self())
    :ok
  end

  defp encoded_notification_bytes(method, params) do
    notification("", method, params)
    |> Jason.encode_to_iodata!()
    |> IO.iodata_length()
  end

  defp encoded_id_bytes(id) do
    id
    |> Jason.encode_to_iodata!()
    |> IO.iodata_length()
    |> Kernel.-(2)
  end

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout) when is_integer(timeout), do: timeout + 1_000

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
      resource_subset?(honored.resource_subscriptions, requested.resource_subscriptions)
  end

  defp resource_subset?(honored, requested) do
    requested = MapSet.new(requested)
    Enum.all?(honored, &MapSet.member?(requested, &1))
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
