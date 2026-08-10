defmodule MCP.Test.EchoHandler do
  @moduledoc """
  Test-support handler for the `handler_opts` acceptance tests (MES-5).

  Surfaces the identity bound via `handler_opts` so tests can assert exactly
  what reached the handler. The tools deliberately read the identity from
  handler **state** (never from the tool arguments) — this is the security
  property AC3 exercises.

  Used by `MCP.Transport.StreamableHTTP.ACTest`.
  """
  @behaviour MCP.Server.Handler

  @impl true
  def init(opts) do
    {:ok, %{identity: Keyword.get(opts, :identity), init_opts: opts}}
  end

  @impl true
  def handle_list_tools(_cursor, _context, _config) do
    tools = [
      %{
        "name" => "whoami",
        "description" => "Echo the identity bound into handler state",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "whoami_with_arg",
        "description" => "Echo the bound identity, ignoring any supplied argument",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"identity" => %{"type" => "string"}}
        }
      }
    ]

    {:ok, tools, nil}
  end

  @impl true
  def handle_call_tool("whoami", _args, context, _config) do
    {:ok, [%{"type" => "text", "text" => to_string(context.identity)}]}
  end

  # AC3: reads state.identity and ignores `args` entirely — a same-named
  # tool argument cannot override the pipeline-bound identity.
  def handle_call_tool("whoami_with_arg", _args, context, _config) do
    {:ok, [%{"type" => "text", "text" => to_string(context.identity)}]}
  end

  def handle_call_tool(name, _args, _context, _config) do
    {:error, -32_602, "Unknown tool: #{name}"}
  end
end
