defmodule MCP.Test.FailableTransport do
  @moduledoc false
  use GenServer

  @behaviour MCP.Transport

  @impl true
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def send_message(pid, message), do: GenServer.call(pid, {:send, message})

  @impl true
  def close(pid), do: GenServer.stop(pid, :normal)

  def inject(pid, message), do: GenServer.cast(pid, {:inject, message})
  def fail(pid, reason), do: GenServer.call(pid, {:fail, reason})

  @impl true
  def init(opts),
    do:
      {:ok,
       %{
         owner: Keyword.fetch!(opts, :owner),
         observer: Keyword.fetch!(opts, :observer),
         failure: nil
       }}

  @impl true
  def handle_call({:send, _message}, _from, %{failure: reason} = state) when not is_nil(reason),
    do: {:reply, {:error, reason}, state}

  def handle_call({:send, message}, _from, state) do
    send(state.observer, {:mcp_message, message})
    {:reply, :ok, state}
  end

  def handle_call({:fail, reason}, _from, state),
    do: {:reply, :ok, %{state | failure: reason}}

  @impl true
  def handle_cast({:inject, message}, state) do
    send(state.owner, {:mcp_message, message})
    {:noreply, state}
  end
end
