defmodule MCP.Server.StateHandle do
  @moduledoc """
  Bounded, expiring server-side storage for opaque state handles (SEP-2567).

  A handle may be bound to the authenticated principal that minted it. The
  principal must come from `MCP.Server.ToolContext.identity`, never from tool
  arguments. Bound handles only resolve or consume for that same principal.

  The two-argument `mint/2` and `fetch/2` functions remain available for
  principal-independent state. Prefer their principal-aware counterparts for
  state that belongs to a caller.
  """
  use Agent

  @default_max_entries 10_000
  @default_ttl_ms 300_000

  @type principal :: term()
  @type state :: %{
          entries: %{String.t() => map()},
          expirations: term(),
          insertion_order: term(),
          max_entries: pos_integer(),
          ttl_ms: pos_integer(),
          next_sequence: non_neg_integer()
        }

  @doc """
  Starts a handle store.

  Options are `:name`, `:max_entries` (default #{@default_max_entries}), and
  `:ttl_ms` (default #{@default_ttl_ms}). When capacity is reached, the oldest
  live handle is evicted before a new one is inserted.
  """
  @spec start_link(keyword()) :: Agent.on_start() | {:error, {:invalid_option, atom(), term()}}
  def start_link(opts \\ []) do
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    with :ok <- validate_positive(:max_entries, max_entries),
         :ok <- validate_positive(:ttl_ms, ttl_ms) do
      initial = %{
        entries: %{},
        expirations: :gb_sets.empty(),
        insertion_order: :gb_sets.empty(),
        max_entries: max_entries,
        ttl_ms: ttl_ms,
        next_sequence: 0
      }

      Agent.start_link(fn -> initial end, Keyword.take(opts, [:name]))
    end
  end

  @doc "Mints a principal-independent handle."
  @spec mint(Agent.agent(), term()) :: String.t()
  def mint(store, value), do: mint(store, value, nil)

  @doc "Mints a handle bound to `principal`."
  @spec mint(Agent.agent(), term(), principal()) :: String.t()
  def mint(store, value, principal) do
    handle = "sh_" <> UUID.uuid4()
    now = now_ms()

    Agent.update(store, fn state ->
      state = state |> discard_expired(now) |> make_room()

      entry = %{
        value: value,
        principal: principal,
        sequence: state.next_sequence,
        expires_at: now + state.ttl_ms
      }

      put_entry(state, handle, entry)
    end)

    handle
  end

  @doc "Fetches a principal-independent handle without consuming it."
  @spec fetch(Agent.agent(), String.t()) :: {:ok, term()} | :error
  def fetch(store, handle), do: fetch(store, handle, nil)

  @doc "Fetches a handle when it is live and bound to `principal`."
  @spec fetch(Agent.agent(), String.t(), principal()) :: {:ok, term()} | :error
  def fetch(store, handle, principal) when is_binary(handle) do
    now = now_ms()

    Agent.get_and_update(store, fn state ->
      state = discard_expired(state, now)
      {resolve(state.entries, handle, principal), state}
    end)
  end

  def fetch(_store, _handle, _principal), do: :error

  @doc "Atomically resolves and removes a principal-independent handle."
  @spec consume(Agent.agent(), String.t()) :: {:ok, term()} | :error
  def consume(store, handle), do: consume(store, handle, nil)

  @doc """
  Atomically resolves and removes a handle bound to `principal`.

  Concurrent consumers therefore have exactly one winner.
  """
  @spec consume(Agent.agent(), String.t(), principal()) :: {:ok, term()} | :error
  def consume(store, handle, principal) when is_binary(handle) do
    now = now_ms()

    Agent.get_and_update(store, fn state ->
      state = discard_expired(state, now)

      case resolve(state.entries, handle, principal) do
        {:ok, value} -> {{:ok, value}, remove_entry(state, handle)}
        :error -> {:error, state}
      end
    end)
  end

  def consume(_store, _handle, _principal), do: :error

  @doc """
  Idempotently deletes a principal-independent handle.

  This compatibility API always returns `:ok`, including when the handle is
  absent, expired, or principal-bound. Use `delete/3` when the caller needs a
  checked, principal-aware result.
  """
  @spec delete(Agent.agent(), String.t()) :: :ok
  def delete(store, handle) do
    _result = delete(store, handle, nil)
    :ok
  end

  @doc "Deletes a handle only when it is bound to `principal`."
  @spec delete(Agent.agent(), String.t(), principal()) :: :ok | :error
  def delete(store, handle, principal) when is_binary(handle) do
    now = now_ms()

    Agent.get_and_update(store, fn state ->
      state = discard_expired(state, now)

      case resolve(state.entries, handle, principal) do
        {:ok, _value} -> {:ok, remove_entry(state, handle)}
        :error -> {:error, state}
      end
    end)
  end

  def delete(_store, _handle, _principal), do: :error

  defp resolve(entries, handle, principal) do
    case Map.fetch(entries, handle) do
      {:ok, %{principal: ^principal, value: value}} -> {:ok, value}
      _other -> :error
    end
  end

  defp put_entry(state, handle, entry) do
    expiration_key = {entry.expires_at, entry.sequence, handle}
    insertion_key = {entry.sequence, handle}

    %{
      state
      | entries: Map.put(state.entries, handle, entry),
        expirations: :gb_sets.add(expiration_key, state.expirations),
        insertion_order: :gb_sets.add(insertion_key, state.insertion_order),
        next_sequence: state.next_sequence + 1
    }
  end

  defp discard_expired(state, now) do
    if :gb_sets.is_empty(state.expirations) do
      state
    else
      {expires_at, _sequence, handle} = :gb_sets.smallest(state.expirations)

      if expires_at <= now do
        state |> remove_entry(handle) |> discard_expired(now)
      else
        state
      end
    end
  end

  defp make_room(state) when map_size(state.entries) < state.max_entries, do: state

  defp make_room(state) do
    {_sequence, oldest_handle} = :gb_sets.smallest(state.insertion_order)
    remove_entry(state, oldest_handle)
  end

  defp remove_entry(state, handle) do
    case Map.pop(state.entries, handle) do
      {nil, _entries} ->
        state

      {entry, entries} ->
        %{
          state
          | entries: entries,
            expirations:
              :gb_sets.delete_any(
                {entry.expires_at, entry.sequence, handle},
                state.expirations
              ),
            insertion_order: :gb_sets.delete_any({entry.sequence, handle}, state.insertion_order)
        }
    end
  end

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, value), do: {:error, {:invalid_option, name, value}}

  defp now_ms, do: System.monotonic_time(:millisecond)
end
