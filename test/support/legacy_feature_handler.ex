defmodule MCP.Test.LegacyFeatureHandler do
  @moduledoc false
  @behaviour MCP.Server.Handler

  alias MCP.Server.ToolContext

  @impl true
  def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

  @impl true
  def handle_list_resources(_cursor, %ToolContext{}, _config), do: {:ok, [], nil}

  @impl true
  def handle_subscribe(uri, %ToolContext{} = context, config) do
    send(config.test_pid, {:subscribed, uri, context.identity})
    :ok
  end

  @impl true
  def handle_unsubscribe(uri, %ToolContext{} = context, config) do
    send(config.test_pid, {:unsubscribed, uri, context.identity})
    :ok
  end

  @impl true
  def handle_set_log_level(level, %ToolContext{} = context, config) do
    send(config.test_pid, {:log_level, level, context.identity})
    :ok
  end
end
