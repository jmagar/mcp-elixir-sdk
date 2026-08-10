defmodule MCP.Test.BlockingLegacyHandler do
  @moduledoc false

  @behaviour MCP.Server.Handler

  alias MCP.Server.ToolContext

  @impl true
  def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

  @impl true
  def handle_call_tool("block", _arguments, %ToolContext{}, %{test_pid: test_pid}) do
    send(test_pid, {:legacy_handler_blocked, self()})

    receive do
      :release_legacy_handler -> {:ok, [%{"type" => "text", "text" => "released"}]}
    end
  end

  def handle_call_tool(_name, _arguments, %ToolContext{}, _state),
    do: {:error, -32_602, "unknown tool"}
end
