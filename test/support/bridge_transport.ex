defmodule MCP.Test.BridgeTransport do
  @moduledoc """
  A transport pair for in-process integration testing.

  Creates two linked transport endpoints. Messages sent via one side are
  delivered to the owner of the other side as `{:mcp_message, msg}`.

  ## Usage

      {client_t, server_t} = BridgeTransport.create_pair()

      {:ok, client} = MCP.Client.start_link(
        transport: {BridgeTransport, pid: client_t},
        ...
      )

      {:ok, server} = MCP.Server.start_link(
        transport: {BridgeTransport, pid: server_t},
        ...
      )
  """

  use GenServer

  @behaviour MCP.Transport

  defstruct [:owner, :peer, :closed]

  @doc """
  Creates a pair of linked bridge endpoints. Returns `{pid_a, pid_b}`.
  """
  def create_pair do
    {:ok, a} = GenServer.start_link(__MODULE__, :no_owner)
    {:ok, b} = GenServer.start_link(__MODULE__, :no_owner)
    GenServer.call(a, {:set_peer, b})
    GenServer.call(b, {:set_peer, a})
    {a, b}
  end

  # --- Transport behaviour ---

  @impl MCP.Transport
  def start_link(opts) do
    pid = Keyword.fetch!(opts, :pid)
    owner = Keyword.fetch!(opts, :owner)
    GenServer.call(pid, {:set_owner, owner})
    {:ok, pid}
  end

  @impl MCP.Transport
  def send_message(pid, message) when is_map(message) do
    GenServer.call(pid, {:send_message, message})
  end

  @impl MCP.Transport
  def close(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Blocks until every message already sent through `pid` has reached the peer
  owner's mailbox.

  `send_message/2` returns once the peer has been *cast* to, so a caller that
  immediately inspects the peer's owner can overtake its own message. Draining
  the peer closes that window.
  """
  def sync(pid) do
    peer = GenServer.call(pid, :peer)
    _ = :sys.get_state(peer)
    :ok
  end

  # --- GenServer ---

  @impl GenServer
  def init(:no_owner) do
    {:ok, %__MODULE__{owner: nil, peer: nil, closed: false}}
  end

  @impl GenServer
  def handle_call({:set_peer, peer}, _from, state) do
    {:reply, :ok, %{state | peer: peer}}
  end

  def handle_call({:set_owner, owner}, _from, state) do
    {:reply, :ok, %{state | owner: owner}}
  end

  def handle_call(:peer, _from, state) do
    {:reply, state.peer, state}
  end

  def handle_call({:send_message, _message}, _from, %{closed: true} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:send_message, message}, _from, state) do
    GenServer.cast(state.peer, {:deliver, message})
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state) do
    if state.owner do
      send(state.owner, {:mcp_transport_closed, :normal})
    end

    {:reply, :ok, %{state | closed: true}}
  end

  @impl GenServer
  def handle_cast({:deliver, message}, state) do
    if state.owner do
      send(state.owner, {:mcp_message, message})
    end

    {:noreply, state}
  end
end
