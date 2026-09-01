defmodule MCP.Transport.StreamableHTTP.LegacySessionManager do
  @moduledoc "Stable indexed runtime owner for stateful Streamable HTTP sessions."
  use GenServer

  alias MCP.Transport.StreamableHTTP.LegacySession
  @sweep_interval 30_000
  @default_max_pending_calls 1_024

  @typedoc false
  @type session :: %{server: pid(), transport: pid()}

  defstruct sessions: %{},
            endpoint_sessions: %{},
            endpoint_counts: %{},
            identity_counts: %{},
            process_refs: %{},
            owner_refs: %{},
            expirations: nil,
            pending: %{},
            task_supervisor: nil,
            sweep_interval: @sweep_interval,
            max_pending_calls: @default_max_pending_calls

  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def create(manager, endpoint_id, identity, handler_module, handler_opts, server_opts, limits) do
    timeout = Keyword.get(limits, :initialization_timeout, 30_000)

    bounded_call(
      manager,
      {:create, endpoint_id, identity, handler_module, handler_opts, server_opts, limits},
      timeout + 5_000
    )
  end

  @spec lookup(GenServer.server(), term(), String.t(), term()) ::
          {:ok, session()} | {:error, :identity_mismatch} | :error
  def lookup(manager, endpoint_id, session_id, identity),
    do: lookup(manager, endpoint_id, session_id, identity, identity)

  def lookup(manager, endpoint_id, session_id, identity, authorization_context),
    do: bounded_call(manager, {:lookup, endpoint_id, session_id, identity, authorization_context})

  def delete(manager, endpoint_id, session_id),
    do: bounded_call(manager, {:delete, endpoint_id, session_id})

  def list(manager, endpoint_id), do: bounded_call(manager, {:list, endpoint_id})

  def sweep(manager, now \\ System.monotonic_time(:millisecond)),
    do: bounded_call(manager, {:sweep, now})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    interval = Keyword.get(opts, :sweep_interval, @sweep_interval)
    max_pending_calls = Keyword.get(opts, :max_pending_calls, @default_max_pending_calls)

    unless is_integer(max_pending_calls) and max_pending_calls > 0 do
      raise ArgumentError, ":max_pending_calls must be a positive integer"
    end

    :persistent_term.put(
      admission_key(self()),
      {:atomics.new(1, signed: false), max_pending_calls}
    )

    with {:ok, supervisor} <- Task.Supervisor.start_link() do
      schedule_sweep(interval)

      {:ok,
       %__MODULE__{
         task_supervisor: supervisor,
         expirations: :gb_sets.empty(),
         sweep_interval: interval,
         max_pending_calls: max_pending_calls
       }}
    end
  end

  defp bounded_call(manager, message, timeout \\ 5_000) do
    with pid when is_pid(pid) <- GenServer.whereis(manager),
         {counter, limit} <- :persistent_term.get(admission_key(pid), :missing),
         :ok <- acquire_admission(counter, limit) do
      try do
        GenServer.call(pid, message, timeout)
      after
        :atomics.sub(counter, 1, 1)
      end
    else
      nil -> exit({:noproc, {GenServer, :call, [manager, message, timeout]}})
      :missing -> {:error, :manager_unavailable}
      {:error, :manager_overloaded} = error -> error
    end
  end

  defp acquire_admission(counter, limit) do
    current = :atomics.get(counter, 1)

    cond do
      current >= limit -> {:error, :manager_overloaded}
      :atomics.compare_exchange(counter, 1, current, current + 1) == :ok -> :ok
      true -> acquire_admission(counter, limit)
    end
  end

  defp admission_key(pid), do: {__MODULE__, :admission_limit, pid}

  @impl true
  def handle_call(
        {:create, endpoint_id, identity, module, handler_opts, server_opts, limits},
        from,
        state
      ) do
    now = System.monotonic_time(:millisecond)
    identity_fp = fingerprint(identity)
    authorization_fp = fingerprint(Keyword.get(limits, :authorization_context, identity))

    with {:ok, owner} <- resolve_owner(Keyword.fetch!(limits, :endpoint_owner)),
         {:ok, state} <- ensure_capacity(state, endpoint_id, identity_fp, limits, now) do
      state = reserve(state, endpoint_id, identity_fp)
      owner_ref = Process.monitor(owner)

      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          # The initialization task owns every partially started child. If its
          # deadline expires, terminating the task also tears down the linked
          # transport and connection instead of leaving an untracked session.
          LegacySession.start_linked(
            module,
            handler_opts,
            server_opts,
            Keyword.fetch!(limits, :protocol_version)
          )
        end)

      requester_ref = Process.monitor(elem(from, 0))
      initialization_timeout = Keyword.get(limits, :initialization_timeout, 30_000)

      timer_ref =
        Process.send_after(self(), {:initialization_timeout, task.ref}, initialization_timeout)

      reservation = %{
        from: from,
        task_pid: task.pid,
        endpoint_id: endpoint_id,
        identity_fingerprint: identity_fp,
        authorization_fingerprint: authorization_fp,
        last_used: now,
        absolute_expires_at: now + Keyword.fetch!(limits, :absolute_timeout),
        idle_timeout: Keyword.fetch!(limits, :idle_timeout),
        endpoint_owner_ref: owner_ref,
        requester_ref: requester_ref,
        timer_ref: timer_ref
      }

      {:noreply,
       %{
         state
         | pending: Map.put(state.pending, task.ref, reservation),
           owner_refs:
             state.owner_refs
             |> Map.put(owner_ref, {:pending, task.ref})
             |> Map.put(requester_ref, {:requester, task.ref})
       }}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lookup, endpoint_id, id, identity, authorization}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state.sessions, id) do
      %{endpoint_id: ^endpoint_id} = entry ->
        finish_lookup(state, id, entry, fingerprint(identity), fingerprint(authorization), now)

      _ ->
        {:reply, :error, state}
    end
  end

  def handle_call({:delete, endpoint_id, id}, _from, state) do
    case Map.get(state.sessions, id) do
      %{endpoint_id: ^endpoint_id} -> {:reply, :ok, remove_session(state, id)}
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call({:list, endpoint_id}, _from, state) do
    state = expire_sessions(state, System.monotonic_time(:millisecond))
    ids = Map.get(state.endpoint_sessions, endpoint_id, MapSet.new())
    sessions = Enum.map(ids, fn id -> {id, state.sessions[id].session.server} end)
    {:reply, sessions, state}
  end

  def handle_call({:sweep, now}, _from, state), do: {:reply, :ok, expire_sessions(state, now)}

  defp finish_lookup(state, id, entry, identity_fp, authorization_fp, now) do
    cond do
      now >= entry.expires_at ->
        {:reply, :error, remove_session(state, id)}

      not Process.alive?(entry.session.server) or not Process.alive?(entry.session.transport) ->
        {:reply, :error, remove_session(state, id)}

      :crypto.hash_equals(entry.identity_fingerprint, identity_fp) and
          :crypto.hash_equals(entry.authorization_fingerprint, authorization_fp) ->
        old_expires_at = entry.expires_at
        expires_at = min(entry.absolute_expires_at, now + entry.idle_timeout)
        entry = %{entry | last_used: now, expires_at: expires_at}

        expirations = :gb_sets.delete_any({old_expires_at, id}, state.expirations)

        state = %{
          state
          | sessions: Map.put(state.sessions, id, entry),
            expirations: :gb_sets.add({expires_at, id}, expirations)
        }

        {:reply, {:ok, entry.session}, state}

      true ->
        {:reply, {:error, :identity_mismatch}, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep(state.sweep_interval)
    {:noreply, expire_sessions(state, System.monotonic_time(:millisecond))}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        if match?({:ok, _session}, result) do
          {:ok, session} = result
          close_session(session)
        end

        {:noreply, state}

      {reservation, pending} ->
        Process.demonitor(ref, [:flush])
        state = cleanup_pending_refs(%{state | pending: pending}, reservation)
        complete_create(state, reservation, result)
    end
  end

  def handle_info({:initialization_timeout, task_ref}, state) do
    cancel_pending(state, task_ref, :initialization_timeout)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      Map.has_key?(state.pending, ref) -> fail_pending(state, ref, reason)
      id = Map.get(state.process_refs, ref) -> {:noreply, remove_session(state, id)}
      owner = Map.get(state.owner_refs, ref) -> owner_down(state, ref, owner)
      true -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, supervisor, reason}, %{task_supervisor: supervisor} = state),
    do: {:stop, {:task_supervisor_exit, reason}, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp complete_create(state, reservation, {:ok, session}) do
    id = UUID.uuid4()

    expires_at =
      min(reservation.absolute_expires_at, reservation.last_used + reservation.idle_timeout)

    entry =
      reservation
      |> Map.drop([:from, :task_pid, :requester_ref, :timer_ref])
      |> Map.merge(%{session: session, expires_at: expires_at})

    state = put_reserved_session(state, id, entry)
    GenServer.reply(reservation.from, {:ok, id, session})
    {:noreply, state}
  end

  defp complete_create(state, reservation, {:error, reason}) do
    state = release_reservation(state, reservation)
    GenServer.reply(reservation.from, {:error, reason})
    {:noreply, state}
  end

  defp fail_pending(state, ref, reason) do
    {reservation, pending} = Map.pop(state.pending, ref)
    state = cleanup_pending_refs(%{state | pending: pending}, reservation)
    state = release_reservation(state, reservation)
    GenServer.reply(reservation.from, {:error, reason})
    {:noreply, state}
  end

  defp owner_down(state, ref, {:pending, task_ref}) do
    case Map.pop(state.pending, task_ref) do
      {nil, _} ->
        {:noreply, %{state | owner_refs: Map.delete(state.owner_refs, ref)}}

      {reservation, pending} ->
        _ = Task.Supervisor.terminate_child(state.task_supervisor, reservation.task_pid)
        Process.demonitor(task_ref, [:flush])
        state = cleanup_pending_refs(%{state | pending: pending}, reservation)
        state = release_reservation(state, reservation, false)
        GenServer.reply(reservation.from, {:error, :endpoint_unavailable})
        {:noreply, state}
    end
  end

  defp owner_down(state, _ref, {:requester, task_ref}),
    do: cancel_pending(state, task_ref, :requester_down)

  defp owner_down(state, ref, {:session, id}),
    do: {:noreply, remove_session(%{state | owner_refs: Map.delete(state.owner_refs, ref)}, id)}

  defp ensure_capacity(state, endpoint_id, identity_fp, limits, now) do
    case capacity_available(state, endpoint_id, identity_fp, limits) do
      :ok ->
        {:ok, state}

      {:error, _} ->
        state = expire_sessions(state, now)

        case capacity_available(state, endpoint_id, identity_fp, limits) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp capacity_available(state, endpoint_id, identity_fp, limits) do
    endpoint_count = Map.get(state.endpoint_counts, endpoint_id, 0)
    identity_count = Map.get(state.identity_counts, {endpoint_id, identity_fp}, 0)

    cond do
      endpoint_count >= Keyword.fetch!(limits, :session_limit) -> {:error, :session_limit}
      identity_count >= Keyword.fetch!(limits, :per_identity_limit) -> {:error, :identity_limit}
      true -> :ok
    end
  end

  defp reserve(state, endpoint_id, identity_fp) do
    key = {endpoint_id, identity_fp}

    %{
      state
      | endpoint_counts: Map.update(state.endpoint_counts, endpoint_id, 1, &(&1 + 1)),
        identity_counts: Map.update(state.identity_counts, key, 1, &(&1 + 1))
    }
  end

  defp release_reservation(state, reservation, demonitor? \\ true) do
    if demonitor?, do: Process.demonitor(reservation.endpoint_owner_ref, [:flush])
    key = {reservation.endpoint_id, reservation.identity_fingerprint}

    %{
      state
      | owner_refs: Map.delete(state.owner_refs, reservation.endpoint_owner_ref),
        endpoint_counts: decrement(state.endpoint_counts, reservation.endpoint_id),
        identity_counts: decrement(state.identity_counts, key)
    }
  end

  defp cancel_pending(state, task_ref, reason) do
    case Map.pop(state.pending, task_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {reservation, pending} ->
        _ = Task.Supervisor.terminate_child(state.task_supervisor, reservation.task_pid)
        Process.demonitor(task_ref, [:flush])
        state = cleanup_pending_refs(%{state | pending: pending}, reservation)
        state = release_reservation(state, reservation)
        if reason != :requester_down, do: GenServer.reply(reservation.from, {:error, reason})
        {:noreply, state}
    end
  end

  defp cleanup_pending_refs(state, reservation) do
    Process.cancel_timer(reservation.timer_ref)
    Process.demonitor(reservation.requester_ref, [:flush])

    %{
      state
      | owner_refs:
          state.owner_refs
          |> Map.delete(reservation.endpoint_owner_ref)
          |> Map.delete(reservation.requester_ref)
    }
  end

  defp expire_sessions(state, now) do
    if :gb_sets.is_empty(state.expirations) do
      state
    else
      {{expires_at, id}, rest} = :gb_sets.take_smallest(state.expirations)
      state = %{state | expirations: rest}

      cond do
        expires_at > now ->
          %{state | expirations: :gb_sets.add({expires_at, id}, rest)}

        match?(%{expires_at: ^expires_at}, Map.get(state.sessions, id)) ->
          state |> remove_session(id) |> expire_sessions(now)

        true ->
          expire_sessions(state, now)
      end
    end
  end

  defp put_reserved_session(state, id, entry) do
    server_ref = Process.monitor(entry.session.server)
    transport_ref = Process.monitor(entry.session.transport)
    entry = Map.put(entry, :process_refs, [server_ref, transport_ref])

    endpoint_sessions =
      Map.update(
        state.endpoint_sessions,
        entry.endpoint_id,
        MapSet.new([id]),
        &MapSet.put(&1, id)
      )

    process_refs = state.process_refs |> Map.put(server_ref, id) |> Map.put(transport_ref, id)

    %{
      state
      | sessions: Map.put(state.sessions, id, entry),
        endpoint_sessions: endpoint_sessions,
        process_refs: process_refs,
        owner_refs: Map.put(state.owner_refs, entry.endpoint_owner_ref, {:session, id}),
        expirations: :gb_sets.add({entry.expires_at, id}, state.expirations)
    }
  end

  defp remove_session(state, id) do
    case Map.pop(state.sessions, id) do
      {nil, _} ->
        state

      {entry, sessions} ->
        close_entry(entry)
        key = {entry.endpoint_id, entry.identity_fingerprint}
        endpoint_sessions = delete_from_set(state.endpoint_sessions, entry.endpoint_id, id)
        process_refs = Enum.reduce(entry.process_refs, state.process_refs, &Map.delete(&2, &1))

        %{
          state
          | sessions: sessions,
            endpoint_sessions: endpoint_sessions,
            process_refs: process_refs,
            owner_refs: Map.delete(state.owner_refs, entry.endpoint_owner_ref),
            endpoint_counts: decrement(state.endpoint_counts, entry.endpoint_id),
            identity_counts: decrement(state.identity_counts, key)
        }
    end
  end

  defp delete_from_set(map, key, value) do
    case Map.fetch(map, key) do
      {:ok, set} ->
        case MapSet.delete(set, value) do
          updated when map_size(updated) == 0 -> Map.delete(map, key)
          updated -> Map.put(map, key, updated)
        end

      :error ->
        map
    end
  end

  defp decrement(counts, key) do
    case Map.get(counts, key, 0) do
      count when count <= 1 -> Map.delete(counts, key)
      count -> Map.put(counts, key, count - 1)
    end
  end

  @impl true
  def terminate(_reason, state) do
    :persistent_term.erase(admission_key(self()))
    Enum.each(state.sessions, fn {_id, entry} -> close_entry(entry) end)
    :ok
  end

  defp close_entry(entry) do
    Process.demonitor(entry.endpoint_owner_ref, [:flush])
    Enum.each(entry.process_refs, &Process.demonitor(&1, [:flush]))
    close_session(entry.session)
  end

  defp close_session(session) do
    if Process.alive?(session.server), do: Process.exit(session.server, :shutdown)

    if Process.alive?(session.transport),
      do: Process.exit(session.transport, :shutdown)
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)

  defp fingerprint(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))

  defp resolve_owner(pid) when is_pid(pid),
    do: if(Process.alive?(pid), do: {:ok, pid}, else: {:error, :endpoint_unavailable})

  defp resolve_owner(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :endpoint_unavailable}
    end
  end

  defp resolve_owner(_), do: {:error, :endpoint_unavailable}
end
