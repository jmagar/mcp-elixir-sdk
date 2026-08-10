defmodule MCP.Test.ClientReviewTransport do
  @moduledoc false

  use GenServer

  @behaviour MCP.Transport

  @impl MCP.Transport
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl MCP.Transport
  def send_message(pid, message), do: send_message(pid, message, [])

  @impl MCP.Transport
  def send_message(pid, message, opts),
    do: GenServer.call(pid, {:send_message, message, opts})

  @impl MCP.Transport
  def close(pid), do: GenServer.call(pid, :close)

  def inject(pid, message), do: GenServer.cast(pid, {:inject, message})

  def fail_next(pid, method, reason), do: GenServer.call(pid, {:fail_next, method, reason})

  @impl true
  def init(opts) do
    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       observer: Keyword.get(opts, :observer, self()),
       close_error: Keyword.get(opts, :close_error),
       failures: %{}
     }}
  end

  @impl true
  def handle_call({:send_message, message, opts}, _from, state) do
    method = Map.get(message, "method")
    send(state.observer, {:client_review_sent, self(), message, opts})

    case Map.pop(state.failures, method) do
      {nil, failures} -> {:reply, :ok, %{state | failures: failures}}
      {reason, failures} -> {:reply, {:error, reason}, %{state | failures: failures}}
    end
  end

  def handle_call({:fail_next, method, reason}, _from, state) do
    {:reply, :ok, %{state | failures: Map.put(state.failures, method, reason)}}
  end

  def handle_call(:close, _from, %{close_error: nil} = state), do: {:reply, :ok, state}

  def handle_call(:close, _from, state), do: {:reply, {:error, state.close_error}, state}

  @impl true
  def handle_cast({:inject, message}, state) do
    send(state.owner, {:mcp_message, message})
    {:noreply, state}
  end
end
