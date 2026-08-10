defmodule MCP.Transport.StreamableHTTP.LegacySession do
  @moduledoc false

  use GenServer

  @behaviour MCP.Transport

  alias MCP.Server.Connection

  defstruct owner: nil,
            owner_ref: nil,
            pending_posts: %{},
            events: :queue.new(),
            event_queue_limit: 256,
            pending_post_limit: 256,
            notification_limit: 256,
            event_waiter: nil,
            closed?: false

  @type session :: %{required(:server) => pid(), required(:transport) => pid()}

  @spec start(module(), keyword(), keyword()) :: {:ok, session()} | {:error, term()}
  def start(handler_module, handler_opts, server_opts) do
    case GenServer.start(__MODULE__, []) do
      {:ok, transport} ->
        case GenServer.start(
               Connection,
               [
                 transport: {__MODULE__, [pid: transport]},
                 handler: {handler_module, handler_opts}
               ] ++ server_opts
             ) do
          {:ok, server} ->
            {:ok, %{server: server, transport: transport}}

          {:error, reason} ->
            close(transport)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def start_linked(handler_module, handler_opts, server_opts) do
    case GenServer.start_link(__MODULE__, []) do
      {:ok, transport} ->
        case Connection.start_link(
               [
                 transport: {__MODULE__, [pid: transport]},
                 handler: {handler_module, handler_opts}
               ] ++ server_opts
             ) do
          {:ok, server} ->
            {:ok, %{server: server, transport: transport}}

          {:error, reason} ->
            close(transport)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec deliver(session(), map(), timeout()) ::
          {:ok, map(), [map()]} | :accepted | {:error, term()}
  def deliver(session, %{"id" => _id, "method" => _method} = message, timeout) do
    request_ref = make_ref()

    GenServer.call(
      session.transport,
      {:request, request_ref, message, timeout},
      extended_timeout(timeout)
    )
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, reason -> {:error, {:session_closed, reason}}
  end

  def deliver(session, message, _timeout) when is_map(message) do
    with {:ok, owner} <- GenServer.call(session.transport, {:deliver, message}),
         _state <- :sys.get_state(owner) do
      :accepted
    else
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:session_closed, reason}}
  end

  @spec next_event(session(), timeout()) :: {:ok, map()} | {:error, term()}
  def next_event(session, timeout) do
    waiter_ref = make_ref()

    GenServer.call(
      session.transport,
      {:next_event, waiter_ref, timeout},
      extended_timeout(timeout)
    )
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, reason -> {:error, {:session_closed, reason}}
  end

  @impl MCP.Transport
  def start_link(opts) do
    transport = Keyword.fetch!(opts, :pid)
    owner = Keyword.fetch!(opts, :owner)

    case GenServer.call(transport, {:set_owner, owner}) do
      :ok -> {:ok, transport}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl MCP.Transport
  def send_message(transport, message), do: GenServer.call(transport, {:send_message, message})

  @doc false
  def send_request_notification(transport, request_id, message),
    do: GenServer.call(transport, {:request_notification, request_id, message})

  @spec close(session() | pid()) :: :ok
  def close(%{server: server}), do: Connection.close(server)

  @impl MCP.Transport
  def close(transport) when is_pid(transport) do
    GenServer.call(transport, :close)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl GenServer
  def handle_call({:set_owner, owner}, _from, %{owner: nil} = state) do
    {:reply, :ok, %{state | owner: owner, owner_ref: Process.monitor(owner)}}
  end

  def handle_call({:set_owner, _owner}, _from, state),
    do: {:reply, {:error, :owner_already_set}, state}

  def handle_call({:request, _request_ref, _message, _timeout}, _from, %{closed?: true} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:request, request_ref, %{"id" => id} = message, timeout}, from, state) do
    cond do
      Map.has_key?(state.pending_posts, id) ->
        {:reply, {:error, :duplicate_request_id}, state}

      map_size(state.pending_posts) >= state.pending_post_limit ->
        {:reply, {:error, :queue_overflow}, state}

      true ->
        send(state.owner, {:mcp_message, message})
        caller = elem(from, 0)

        pending = %{
          from: from,
          request_ref: request_ref,
          caller_ref: Process.monitor(caller),
          timeout_ref: schedule_timeout({:request_timeout, id, request_ref}, timeout),
          notifications: []
        }

        {:noreply, %{state | pending_posts: Map.put(state.pending_posts, id, pending)}}
    end
  end

  def handle_call({:deliver, _message}, _from, %{closed?: true} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:deliver, message}, _from, state) do
    send(state.owner, {:mcp_message, message})
    {:reply, {:ok, state.owner}, state}
  end

  def handle_call({:send_message, %{"id" => id} = response}, _from, state)
      when is_map_key(response, "result") or is_map_key(response, "error") do
    case Map.pop(state.pending_posts, id) do
      {nil, _pending} ->
        enqueue_event(response, state)

      {%{from: waiter, notifications: notifications} = completed, pending} ->
        cleanup_pending_waiter(completed)
        GenServer.reply(waiter, {:ok, response, Enum.reverse(notifications)})
        {:reply, :ok, %{state | pending_posts: pending}}
    end
  end

  def handle_call({:send_message, message}, _from, state), do: enqueue_event(message, state)

  def handle_call({:request_notification, request_id, message}, _from, state) do
    case Map.fetch(state.pending_posts, request_id) do
      {:ok, pending} ->
        if length(pending.notifications) < state.notification_limit do
          pending = %{pending | notifications: [message | pending.notifications]}

          {:reply, :ok,
           %{state | pending_posts: Map.put(state.pending_posts, request_id, pending)}}
        else
          {:reply, {:error, :queue_overflow}, state}
        end

      :error ->
        enqueue_event(message, state)
    end
  end

  def handle_call({:next_event, _waiter_ref, _timeout}, _from, %{closed?: true} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:next_event, waiter_ref, timeout}, from, state) do
    case :queue.out(state.events) do
      {{:value, event}, events} -> {:reply, {:ok, event}, %{state | events: events}}
      {:empty, _events} -> put_event_waiter(from, waiter_ref, timeout, state)
    end
  end

  def handle_call(:close, _from, state) do
    state = fail_waiters(state, :closed)
    {:stop, :normal, :ok, %{state | closed?: true}}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, owner, _reason}, %{owner: owner, owner_ref: ref} = state) do
    state = fail_waiters(state, :closed)
    {:stop, :normal, %{state | closed?: true}}
  end

  def handle_info({:request_timeout, id, request_ref}, state) do
    case Map.get(state.pending_posts, id) do
      %{request_ref: ^request_ref} = pending ->
        cleanup_pending_waiter(pending)
        GenServer.reply(pending.from, {:error, :timeout})
        {:noreply, %{state | pending_posts: Map.delete(state.pending_posts, id)}}

      _missing ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:event_timeout, waiter_ref},
        %{event_waiter: %{waiter_ref: waiter_ref}} = state
      ) do
    cleanup_event_waiter(state.event_waiter)
    GenServer.reply(state.event_waiter.from, {:error, :timeout})
    {:noreply, %{state | event_waiter: nil}}
  end

  def handle_info({:event_timeout, _waiter_ref}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case pending_by_monitor(state.pending_posts, ref) do
      {id, pending} ->
        cleanup_pending_waiter(pending)
        {:noreply, %{state | pending_posts: Map.delete(state.pending_posts, id)}}

      nil ->
        if state.event_waiter && state.event_waiter.caller_ref == ref do
          cleanup_event_waiter(state.event_waiter)
          {:noreply, %{state | event_waiter: nil}}
        else
          {:noreply, state}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp enqueue_event(message, %{event_waiter: waiter} = state) when not is_nil(waiter) do
    cleanup_event_waiter(waiter)
    GenServer.reply(waiter.from, {:ok, message})
    {:reply, :ok, %{state | event_waiter: nil}}
  end

  defp enqueue_event(message, state) do
    if :queue.len(state.events) < state.event_queue_limit do
      {:reply, :ok, %{state | events: :queue.in(message, state.events)}}
    else
      {:reply, {:error, :queue_overflow}, state}
    end
  end

  defp put_event_waiter(from, waiter_ref, timeout, %{event_waiter: nil} = state) do
    waiter = %{
      from: from,
      waiter_ref: waiter_ref,
      caller_ref: Process.monitor(elem(from, 0)),
      timeout_ref: schedule_timeout({:event_timeout, waiter_ref}, timeout)
    }

    {:noreply, %{state | event_waiter: waiter}}
  end

  defp put_event_waiter(_from, _waiter_ref, _timeout, state),
    do: {:reply, {:error, :event_waiter_exists}, state}

  defp fail_waiters(state, reason) do
    Enum.each(state.pending_posts, fn {_id, pending} ->
      cleanup_pending_waiter(pending)
      GenServer.reply(pending.from, {:error, reason})
    end)

    case state.event_waiter do
      waiter when is_map(waiter) ->
        cleanup_event_waiter(waiter)
        GenServer.reply(waiter.from, {:error, reason})

      nil ->
        :ok
    end

    %{state | pending_posts: %{}, event_waiter: nil}
  end

  defp cleanup_pending_waiter(pending) do
    cancel_timer(pending.timeout_ref)
    Process.demonitor(pending.caller_ref, [:flush])
  end

  defp cleanup_event_waiter(waiter) do
    cancel_timer(waiter.timeout_ref)
    Process.demonitor(waiter.caller_ref, [:flush])
  end

  defp pending_by_monitor(pending_posts, ref) do
    Enum.find(pending_posts, fn {_id, pending} -> pending.caller_ref == ref end)
  end

  defp extended_timeout(:infinity), do: :infinity
  defp extended_timeout(timeout), do: timeout + 1_000

  defp schedule_timeout(_message, :infinity), do: nil
  defp schedule_timeout(message, timeout), do: Process.send_after(self(), message, timeout)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer_ref), do: Process.cancel_timer(timer_ref)
end
