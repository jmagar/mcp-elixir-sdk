defmodule MCP.Test.MockTransport do
  @moduledoc """
  In-memory transport for unit testing MCP client/server.

  Collects sent messages and allows injecting incoming messages.
  """

  use GenServer

  @behaviour MCP.Transport

  defstruct [:owner, :sent, :send_options, :closed, :send_error, waiters: []]

  @impl MCP.Transport
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl MCP.Transport
  def send_message(pid, message) do
    send_message(pid, message, [])
  end

  @impl MCP.Transport
  def send_message(pid, message, opts) do
    GenServer.call(pid, {:send_message, message, opts})
  end

  @impl MCP.Transport
  def close(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Inject a message as if it came from the remote side.
  """
  def inject(pid, message) do
    GenServer.cast(pid, {:inject, message})
  end

  @doc """
  Returns all messages sent through this transport.
  """
  def sent_messages(pid) do
    GenServer.call(pid, :sent_messages)
  end

  @doc "Waits until at least `count` messages have been recorded."
  def await_sent(pid, count, timeout \\ 1_000) do
    GenServer.call(pid, {:await_sent, count}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
  end

  @doc """
  Returns the last message sent through this transport, or nil.
  """
  def last_sent(pid) do
    GenServer.call(pid, :last_sent)
  end

  def last_send_options(pid) do
    GenServer.call(pid, :last_send_options)
  end

  @doc """
  Returns whether close has been called.
  """
  def closed?(pid) do
    GenServer.call(pid, :closed?)
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)

    {:ok,
     %__MODULE__{
       owner: owner,
       sent: [],
       send_options: [],
       closed: false,
       send_error: Keyword.get(opts, :send_error)
     }}
  end

  @impl GenServer
  def handle_call({:send_message, message, opts}, _from, state) do
    if state.send_error do
      {:reply, {:error, state.send_error}, state}
    else
      record_message(message, opts, state)
    end
  end

  def handle_call(:close, _from, state) do
    send(state.owner, {:mcp_transport_closed, :normal})
    {:reply, :ok, %{state | closed: true}}
  end

  def handle_call(:sent_messages, _from, state) do
    {:reply, state.sent, state}
  end

  def handle_call({:await_sent, count}, from, state) do
    if length(state.sent) >= count do
      {:reply, {:ok, state.sent}, state}
    else
      {:noreply, %{state | waiters: [{from, count} | state.waiters]}}
    end
  end

  def handle_call(:last_sent, _from, state) do
    {:reply, List.last(state.sent), state}
  end

  def handle_call(:last_send_options, _from, state) do
    {:reply, List.last(state.send_options), state}
  end

  def handle_call(:closed?, _from, state) do
    {:reply, state.closed, state}
  end

  @impl GenServer
  def handle_cast({:inject, message}, state) do
    send(state.owner, {:mcp_message, message})
    {:noreply, state}
  end

  defp record_message(message, opts, state) do
    new_state = %{
      state
      | sent: state.sent ++ [message],
        send_options: state.send_options ++ [opts]
    }

    {ready, waiting} =
      Enum.split_with(new_state.waiters, fn {_from, count} -> length(new_state.sent) >= count end)

    Enum.each(ready, fn {from, _count} -> GenServer.reply(from, {:ok, new_state.sent}) end)

    {:reply, :ok, %{new_state | waiters: waiting}}
  end
end
