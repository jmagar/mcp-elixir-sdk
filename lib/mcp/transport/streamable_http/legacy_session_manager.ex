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

  defstruct sessions: %{}, sweep_interval: @sweep_interval

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
  def lookup(manager, endpoint_id, session_id, identity) do
    GenServer.call(manager, {:lookup, endpoint_id, session_id, identity})
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
    state = expire_sessions(state, now)
    identity_fingerprint = identity_fingerprint(identity)

    with {:ok, endpoint_owner} <- resolve_endpoint_owner(Keyword.fetch!(limits, :endpoint_owner)),
         :ok <- capacity_available(state, endpoint_id, identity_fingerprint, limits),
         {:ok, session} <- LegacySession.start_linked(handler_module, handler_opts, server_opts) do
      session_id = UUID.uuid4()

      entry = %{
        endpoint_id: endpoint_id,
        identity_fingerprint: identity_fingerprint,
        session: session,
        last_used: now,
        absolute_expires_at: now + Keyword.fetch!(limits, :absolute_timeout),
        idle_timeout: Keyword.fetch!(limits, :idle_timeout),
        endpoint_owner_ref: Process.monitor(endpoint_owner)
      }

      {:reply, {:ok, session_id, session}, put_in(state.sessions[session_id], entry)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lookup, endpoint_id, session_id, identity}, _from, state) do
    now = System.monotonic_time(:millisecond)
    state = expire_sessions(state, now)
    presented_fingerprint = identity_fingerprint(identity)

    case Map.get(state.sessions, session_id) do
      %{endpoint_id: ^endpoint_id, identity_fingerprint: expected} = entry ->
        if :crypto.hash_equals(expected, presented_fingerprint) do
          entry = %{entry | last_used: now}
          {:reply, {:ok, entry.session}, put_in(state.sessions[session_id], entry)}
        else
          {:reply, {:error, :identity_mismatch}, state}
        end

      _missing ->
        {:reply, :error, state}
    end
  end

  def handle_call({:delete, endpoint_id, session_id}, _from, state) do
    case Map.pop(state.sessions, session_id) do
      {%{endpoint_id: ^endpoint_id} = entry, sessions} ->
        close_entry(entry)
        {:reply, :ok, %{state | sessions: sessions}}

      {_other, _sessions} ->
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

  @impl GenServer
  def handle_info(:sweep, state) do
    schedule_sweep(state.sweep_interval)
    {:noreply, expire_sessions(state, System.monotonic_time(:millisecond))}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    {expired, retained} =
      Enum.split_with(state.sessions, fn {_id, entry} ->
        entry.session.server == pid or entry.session.transport == pid
      end)

    Enum.each(expired, fn {_id, entry} -> close_entry(entry) end)
    {:noreply, %{state | sessions: Map.new(retained)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {expired, retained} =
      Enum.split_with(state.sessions, fn {_id, entry} -> entry.endpoint_owner_ref == ref end)

    Enum.each(expired, fn {_id, entry} -> close_entry(entry) end)
    {:noreply, %{state | sessions: Map.new(retained)}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.sessions, fn {_id, entry} -> close_entry(entry) end)
    :ok
  end

  defp capacity_available(state, endpoint_id, identity_fingerprint, limits) do
    endpoint_count = Enum.count(state.sessions, fn {_id, e} -> e.endpoint_id == endpoint_id end)

    identity_count =
      Enum.count(state.sessions, fn {_id, e} ->
        e.endpoint_id == endpoint_id and
          :crypto.hash_equals(e.identity_fingerprint, identity_fingerprint)
      end)

    cond do
      endpoint_count >= Keyword.fetch!(limits, :session_limit) -> {:error, :session_limit}
      identity_count >= Keyword.fetch!(limits, :per_identity_limit) -> {:error, :identity_limit}
      true -> :ok
    end
  end

  defp expire_sessions(state, now) do
    {expired, retained} =
      Enum.split_with(state.sessions, fn {_id, entry} ->
        now >= entry.absolute_expires_at or now - entry.last_used >= entry.idle_timeout or
          not Process.alive?(entry.session.server) or
          not Process.alive?(entry.session.transport)
      end)

    Enum.each(expired, fn {_id, entry} -> close_entry(entry) end)
    %{state | sessions: Map.new(retained)}
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
