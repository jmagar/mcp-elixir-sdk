defmodule MCP.Test.LegacySubscribeOnlyHandler do
  @moduledoc false
  @behaviour MCP.Server.Handler

  alias MCP.Server.ToolContext

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_list_resources(_cursor, %ToolContext{}, _config), do: {:ok, [], nil}

  @impl true
  def handle_subscribe(_uri, %ToolContext{}, _config), do: :ok
end
