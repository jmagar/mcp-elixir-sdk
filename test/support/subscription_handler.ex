defmodule MCP.Test.SubscriptionHandler do
  @moduledoc false

  @behaviour MCP.Server.Handler

  alias MCP.Protocol.Types.SubscriptionFilter
  alias MCP.Server.ToolContext

  @impl true
  def init(opts),
    do:
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         block_authorization?: Keyword.get(opts, :block_authorization?, false)
       }}

  @impl true
  def handle_listen_subscriptions(
        %SubscriptionFilter{} = requested,
        %ToolContext{} = context,
        config
      ) do
    send(config.test_pid, {:subscription_authorized, context.request_id, context.identity})

    if config.block_authorization? do
      receive do
        :release_subscription_authorization -> :ok
      end
    end

    {:ok, requested}
  end
end
