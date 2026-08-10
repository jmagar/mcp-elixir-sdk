defmodule MCP.Test.EagerSubscriptionTransport do
  @moduledoc false

  use GenServer

  @behaviour MCP.Transport

  @impl MCP.Transport
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl MCP.Transport
  def send_message(_pid, _message), do: :ok

  @impl MCP.Transport
  def open_subscription(pid, message, _opts),
    do: GenServer.call(pid, {:open_subscription, message})

  @impl MCP.Transport
  def close(pid), do: GenServer.stop(pid, :normal)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       pending: %{},
       invalid_message?: Keyword.get(opts, :invalid_message?, false)
     }}
  end

  @impl GenServer
  def handle_call({:open_subscription, %{"id" => id}}, from, state) do
    delivery_ref = make_ref()

    message =
      if state.invalid_message? do
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/tools/list_changed",
          "params" => %{"_meta" => %{"io.modelcontextprotocol/subscriptionId" => id}}
        }
      else
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/subscriptions/acknowledged",
          "params" => %{
            "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id},
            "notifications" => %{"toolsListChanged" => true}
          }
        }
      end

    send(
      state.owner,
      {:mcp_subscription_message, self(), self(), delivery_ref, message}
    )

    {:noreply, %{state | pending: Map.put(state.pending, delivery_ref, from)}}
  end

  @impl GenServer
  def handle_info({:subscription_delivery_ack, delivery_ref}, state) do
    {from, pending} = Map.pop(state.pending, delivery_ref)
    GenServer.reply(from, :ok)
    {:noreply, %{state | pending: pending}}
  end
end
