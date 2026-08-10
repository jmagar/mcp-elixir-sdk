#!/usr/bin/env elixir
# MCP Conformance Server Adapter
#
# Starts an MCP server over Streamable HTTP for conformance testing.
#
# Usage:
#   mix run conformance/server_adapter.exs [port]
#
# Then run conformance tests:
#   npx @modelcontextprotocol/conformance server --url http://localhost:<port>/mcp
#
# Default port: 3001

# Load the handler module
Code.require_file("server_handler.ex", Path.dirname(__ENV__.file))

port =
  case System.argv() do
    [port_str | _] -> String.to_integer(port_str)
    _ -> 3001
  end

{:ok, _registry} =
  Registry.start_link(keys: :duplicate, name: MCP.Conformance.SubscriptionRegistry)

{:ok, _supervisor} =
  DynamicSupervisor.start_link(
    strategy: :one_for_one,
    name: MCP.Conformance.SubscriptionSupervisor
  )

plug =
  MCP.Transport.StreamableHTTP.Plug.new(
    server_mod: MCP.Conformance.ServerHandler,
    server_opts: [server_info: %{name: "mcp-elixir-sdk", version: "2.0.0-dev.2"}],
    enable_json_response: false,
    protocol_version: "2026-07-28",
    subscription_registry: MCP.Conformance.SubscriptionRegistry,
    subscription_supervisor: MCP.Conformance.SubscriptionSupervisor,
    subscription_endpoint: MCP.Conformance.ServerHandler,
    subscription_keepalive_interval: 250,
    tool_schemas:
      MCP.Conformance.ServerHandler.handle_list_tools(
        nil,
        %MCP.Server.ToolContext{},
        %{}
      )
      |> then(fn {:ok, tools, nil} ->
        Map.new(tools, &{&1["name"], &1["inputSchema"]})
      end)
  )

IO.puts("Starting MCP Conformance Server on http://localhost:#{port}/mcp")

{:ok, _} = Bandit.start_link(plug: plug, port: port, ip: {127, 0, 0, 1})

IO.puts("Server ready. Press Ctrl+C to stop.")

# Block forever
Process.sleep(:infinity)
