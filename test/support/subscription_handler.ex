defmodule MCP.Test.SubscriptionHandler do
  @moduledoc false

  @behaviour MCP.Server.Handler

  alias MCP.Protocol.Types.SubscriptionFilter
  alias MCP.Server.ToolContext

  @impl true
  def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

  @impl true
  def handle_listen_subscriptions(
        %SubscriptionFilter{} = requested,
        %ToolContext{} = context,
        config
      ) do
    send(config.test_pid, {:subscription_authorized, context.request_id, context.identity})
    {:ok, requested}
  end
end
