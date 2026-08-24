Code.require_file("examples/quickstart_server.exs")

defmodule MCP.Examples.QuickstartServerTest do
  use ExUnit.Case, async: true

  alias MCP.Examples.QuickstartServer.Handler
  alias MCP.Server.ToolContext

  test "quick-start server example is executable through the public handler contract" do
    assert {:ok, %{}} = Handler.init([])

    context = %ToolContext{}

    assert {:ok, [%{"name" => "add", "inputSchema" => schema}], nil} =
             Handler.handle_list_tools(nil, context, %{})

    assert %{"required" => ["a", "b"], "type" => "object"} = schema

    assert {:ok, [%{"text" => "42", "type" => "text"}]} =
             Handler.handle_call_tool(
               "add",
               %{"a" => 20, "b" => 22},
               context,
               %{}
             )

    assert {:error, -32_601, "Unknown tool: missing"} =
             Handler.handle_call_tool(
               "missing",
               %{},
               context,
               %{}
             )
  end
end
