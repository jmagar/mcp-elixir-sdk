defmodule MCP.Test.ConnectRetryTransport do
  @moduledoc false

  use Agent

  @behaviour MCP.Transport

  @impl MCP.Transport
  def start_link(opts) do
    Agent.start_link(fn ->
      %{
        owner: Keyword.fetch!(opts, :owner),
        observer: Keyword.fetch!(opts, :observer),
        sends: 0
      }
    end)
  end

  @impl MCP.Transport
  def send_message(pid, message) do
    {observer, attempt} =
      Agent.get_and_update(pid, fn state ->
        next = state.sends + 1
        {{state.observer, next}, %{state | sends: next}}
      end)

    send(observer, {:connect_retry_sent, attempt, message})

    if attempt == 1 do
      receive do
        :never -> :ok
      end
    else
      :ok
    end
  end

  @impl MCP.Transport
  def close(pid), do: Agent.stop(pid, :normal)

  def inject(pid, message) do
    pid
    |> Agent.get(& &1.owner)
    |> send({:mcp_message, message})

    :ok
  end
end
