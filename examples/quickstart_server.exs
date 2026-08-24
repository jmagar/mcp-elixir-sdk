defmodule MCP.Examples.QuickstartServer.Handler do
  @moduledoc """
  Minimal MCP 2.0 tool server used by the README and executable example test.

  Start it over stdio from an application process with:

      MCP.Server.Connection.start_link(
        transport: {MCP.Transport.Stdio, mode: :server},
        handler: {#{inspect(__MODULE__)}, []},
        server_info: %{name: "quickstart_server", version: "1.0.0"}
      )
  """

  @behaviour MCP.Server.Handler

  alias MCP.Server.ToolContext

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_list_tools(_cursor, %ToolContext{}, _config) do
    {:ok,
     [
       %{
         "name" => "add",
         "description" => "Adds two numbers",
         "inputSchema" => %{
           "$schema" => "https://json-schema.org/draft/2020-12/schema",
           "type" => "object",
           "properties" => %{
             "a" => %{"type" => "number"},
             "b" => %{"type" => "number"}
           },
           "required" => ["a", "b"]
         }
       }
     ], nil}
  end

  @impl true
  def handle_call_tool("add", %{"a" => a, "b" => b}, %ToolContext{}, _config)
      when is_number(a) and is_number(b) do
    {:ok, [%{"type" => "text", "text" => to_string(a + b)}]}
  end

  def handle_call_tool(name, _arguments, %ToolContext{}, _config) do
    {:error, -32_601, "Unknown tool: #{name}"}
  end
end

if System.argv() == ["--stdio"] do
  {:ok, _connection} =
    MCP.Server.Connection.start_link(
      transport: {MCP.Transport.Stdio, mode: :server},
      handler: {MCP.Examples.QuickstartServer.Handler, []},
      server_info: %{name: "quickstart_server", version: "1.0.0"}
    )

  Process.sleep(:infinity)
end
