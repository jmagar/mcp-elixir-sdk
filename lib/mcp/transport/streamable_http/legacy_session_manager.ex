defmodule MCP.Transport.StreamableHTTP.LegacySessionManager do
  @moduledoc """
  Stable runtime owner for stateful Streamable HTTP sessions.

  Plug configuration contains only the manager name and an opaque binary
  endpoint ID, so it remains safe for compile-time `Plug.Builder` escaping.
  The manager owns session processes, capacity limits, identity binding, and
  expiration independently of the process that compiled or initialized a Plug.
  """

  use GenServer

  alias MCP.Transport.StreamableHTTP.LegacySession

  @sweep_interval 30_000

  defstruct sessions: %{},
            endpoint_counts: %{},
            identity_counts: %{},
            sweep_interval: @sweep_interval

  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc false
  def create(manager, endpoint_id, identity, handler_module, handler_opts, server_opts, limits) do
    GenServer.call(
      manager,
      {:create, endpoint_id, identity, handler_module, handler_opts, server_opts, limits},
      60_000
    )
  end

  @doc false
  @spec lookup(GenServer.server(), term(), String.t(), term()) ::
          {:ok, LegacySession.session()} | {:error, :identity_mismatch} | :error
  def lookup(manager, endpoint_id, session_id, identity) do
    lookup(manager, endpoint_id, session_id, identity, identity)
  end

  @doc false
  def lookup(manager, endpoint_id, session_id, identity, authorization_context) do
    GenServer.call(
      manager,
      {:lookup, endpoint_id, session_id, identity, authorization_context}
    )
  end

  @doc false
  def delete(manager, endpoint_id, session_id) do
    GenServer.call(manager, {:delete, endpoint_id, session_id})
  end

  @doc false
  def list(manager, endpoint_id), do: GenServer.call(manager, {:list, endpoint_id})

  @doc false
  def sweep(manager, now \\ System.monotonic_time(:millisecond)) do
    GenServer.call(manager, {:sweep, now})
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    interval = Keyword.get(opts, :sweep_interval, @sweep_interval)
    schedule_sweep(interval)
    {:ok, %__MODULE__{sweep_interval: interval}}
  end

  @impl GenServer
  def handle_call(
        {:create, endpoint_id, identity, handler_module, handler_opts, server_opts, limits},
        _from,
        state
      ) do
    now = System.monotonic_time(:millisecond)
    identity_fingerprint = identity_fingerprint(identity)

    authorization_fingerprint =
      identity_fingerprint(Keyword.get(limits, :authorization_context, identity))

    with {:ok, endpoint_owner} <- resolve_endpoint_owner(Keyword.fetch!(limits, :endpoint_owner)),
         {:ok, state} <- ensure_capacity(state, endpoint_id, identity_fingerprint, limits, now),
         {:ok, session} <-
           LegacySession.start_linked(
             handler_module,
             handler_opts,
             server_opts,
             Keyword.fetch!(limits, :protocol_version)
           ) do
      session_id = UUID.uuid4()

      entry = %{
        endpoint_id: endpoint_id,
        identity_fingerprint: identity_fingerprint,
        authorization_fingerprint: authorization_fingerprint,
        session: session,
        last_used: now,
        absolute_expires_at: now + Keyword.fetch!(limits, :absolute_timeout),
        idle_timeout: Keyword.fetch!(limits, :idle_timeout),
        endpoint_owner_ref: Process.monitor(endpoint_owner)
      }

      {:reply, {:ok, session_id, session}, put_session(state, session_id, entry)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:lookup, endpoint_id, session_id, identity, authorization_context},
        _from,
        state
      ) do
    now = System.monotonic_time(:millisecond)
    presented_fingerprint = identity_fingerprint(identity)
    presented_authorization_fingerprint = identity_fingerprint(authorization_context)

    case Map.get(state.sessions, session_id) do
      %{
        endpoint_id: ^endpoint_id,
        identity_fingerprint: expected,
        authorization_fingerprint: expected_authorization
      } = entry ->
        finish_lookup(
          state,
          session_id,
          entry,
          {expected, expected_authorization, presented_fingerprint,
           presented_authorization_fingerprint},
          now
        )

      _missing ->
        {:reply, :error, state}
    end
  end

  def handle_call({:delete, endpoint_id, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      %{endpoint_id: ^endpoint_id} ->
        {:reply, :ok, remove_session(state, session_id)}

      _missing ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:list, endpoint_id}, _from, state) do
    state = expire_sessions(state, System.monotonic_time(:millisecond))

    sessions =
      for {session_id, %{endpoint_id: ^endpoint_id, session: session}} <- state.sessions,
          do: {session_id, session.server}

    {:reply, sessions, state}
  end

  def handle_call({:sweep, now}, _from, state) do
    state = expire_sessions(state, now)
    {:reply, :ok, state}
  end

  defp finish_lookup(state, session_id, entry, _fingerprints, now)
       when now >= entry.absolute_expires_at or now - entry.last_used >= entry.idle_timeout do
    {:reply, :error, remove_session(state, session_id)}
  end

  defp finish_lookup(state, session_id, entry, {expected, expected_auth, presented, auth}, now) do
    cond do
      not Process.alive?(entry.session.server) or not Process.alive?(entry.session.transport) ->
        {:reply, :error, remove_session(state, session_id)}

      :crypto.hash_equals(expected, presented) and :crypto.hash_equals(expected_auth, auth) ->
        entry = %{entry | last_used: now}
        {:reply, {:ok, entry.session}, put_in(state.sessions[session_id], entry)}

      true ->
        {:reply, {:error, :identity_mismatch}, state}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    schedule_sweep(state.sweep_interval)
    {:noreply, expire_sessions(state, System.monotonic_time(:millisecond))}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    state =
      Enum.reduce(state.sessions, state, fn {id, entry}, acc ->
        if entry.session.server == pid or entry.session.transport == pid,
          do: remove_session(acc, id),
          else: acc
      end)

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state =
      Enum.reduce(state.sessions, state, fn {id, entry}, acc ->
        if entry.endpoint_owner_ref == ref, do: remove_session(acc, id), else: acc
      end)

    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.sessions, fn {_id, entry} -> close_entry(entry) end)
    :ok
  end

  defp capacity_available(state, endpoint_id, identity_fingerprint, limits) do
    endpoint_count = Map.get(state.endpoint_counts, endpoint_id, 0)
    identity_count = Map.get(state.identity_counts, {endpoint_id, identity_fingerprint}, 0)

    cond do
      endpoint_count >= Keyword.fetch!(limits, :session_limit) -> {:error, :session_limit}
      identity_count >= Keyword.fetch!(limits, :per_identity_limit) -> {:error, :identity_limit}
      true -> :ok
    end
  end

  defp ensure_capacity(state, endpoint_id, identity_fingerprint, limits, now) do
    case capacity_available(state, endpoint_id, identity_fingerprint, limits) do
      :ok ->
        {:ok, state}

      {:error, _reason} ->
        state = expire_sessions(state, now)

        case capacity_available(state, endpoint_id, identity_fingerprint, limits) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp expire_sessions(state, now) do
    Enum.reduce(state.sessions, state, fn {id, entry}, acc ->
      if expired?(entry, now), do: remove_session(acc, id), else: acc
    end)
  end

  defp expired?(entry, now) do
    now >= entry.absolute_expires_at or now - entry.last_used >= entry.idle_timeout or
      not Process.alive?(entry.session.server) or not Process.alive?(entry.session.transport)
  end

  defp put_session(state, session_id, entry) do
    if Map.has_key?(state.sessions, session_id) do
      put_in(state.sessions[session_id], entry)
    else
      identity_key = {entry.endpoint_id, entry.identity_fingerprint}

      %{
        state
        | sessions: Map.put(state.sessions, session_id, entry),
          endpoint_counts: Map.update(state.endpoint_counts, entry.endpoint_id, 1, &(&1 + 1)),
          identity_counts: Map.update(state.identity_counts, identity_key, 1, &(&1 + 1))
      }
    end
  end

  defp remove_session(state, session_id) do
    case Map.pop(state.sessions, session_id) do
      {nil, _sessions} ->
        state

      {entry, sessions} ->
        close_entry(entry)
        identity_key = {entry.endpoint_id, entry.identity_fingerprint}

        %{
          state
          | sessions: sessions,
            endpoint_counts: decrement_count(state.endpoint_counts, entry.endpoint_id),
            identity_counts: decrement_count(state.identity_counts, identity_key)
        }
    end
  end

  defp decrement_count(counts, key) do
    case Map.get(counts, key, 0) do
      count when count <= 1 -> Map.delete(counts, key)
      count -> Map.put(counts, key, count - 1)
    end
  end

  defp close_entry(entry) do
    Process.demonitor(entry.endpoint_owner_ref, [:flush])
    close_session(entry.session)
  end

  defp close_session(session) do
    if Process.alive?(session.server), do: Process.exit(session.server, :shutdown)
    if Process.alive?(session.transport), do: Process.exit(session.transport, :shutdown)
    :ok
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)

  defp identity_fingerprint(identity) do
    encoded = :erlang.term_to_binary(identity, [:deterministic])
    :crypto.hash(:sha256, encoded)
  end

  defp resolve_endpoint_owner(pid) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :endpoint_unavailable}
  end

  defp resolve_endpoint_owner(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :endpoint_unavailable}
    end
  end

  defp resolve_endpoint_owner(_other), do: {:error, :endpoint_unavailable}
end
