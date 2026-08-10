defmodule MCP.Test.BlockingTransport do
  @moduledoc false

  use GenServer

  @behaviour MCP.Transport

  defstruct [:owner, :observer, :blocked_from]

  @impl MCP.Transport
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl MCP.Transport
  def send_message(pid, message), do: send_message(pid, message, [])

  @impl MCP.Transport
  def send_message(pid, message, _opts), do: GenServer.call(pid, {:send, message}, :infinity)

  @impl MCP.Transport
  def close(pid), do: GenServer.stop(pid, :normal)

  def release(pid, result \\ :ok), do: GenServer.cast(pid, {:release, result})

  @impl GenServer
  def init(opts) do
    {:ok,
     %__MODULE__{
       owner: Keyword.fetch!(opts, :owner),
       observer: Keyword.fetch!(opts, :observer)
     }}
  end

  @impl GenServer
  def handle_call({:send, message}, from, %{blocked_from: nil} = state) do
    send(state.observer, {:transport_send_started, message})
    {:noreply, %{state | blocked_from: from}}
  end

  @impl GenServer
  def handle_cast({:release, result}, %{blocked_from: from} = state) do
    if from, do: GenServer.reply(from, result)
    {:noreply, %{state | blocked_from: nil}}
  end
end
