defmodule MCP.Transport.StreamableHTTPRecoveryTest do
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Test.RoutingRecoveryPlug
  alias MCP.Test.StatelessHandler
  alias MCP.Transport.StreamableHTTP.Client, as: HTTPClient
  alias MCP.Transport.StreamableHTTP.Plug, as: MCPPlug

  test "HTTP HeaderMismatch reaches the client and triggers one schema refresh" do
    state = start_supervised!({Agent, fn -> 0 end})

    bandit =
      start_supervised!(
        {Bandit, plug: {RoutingRecoveryPlug, state: state}, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      start_supervised!(
        {Client,
         transport: {HTTPClient, url: "http://127.0.0.1:#{port}/mcp"},
         client_info: %{name: "recovery-test", version: "1"}}
      )

    assert {:ok, _discover} = Client.connect(client)
    assert {:ok, %{"tools" => [_tool]}} = Client.list_tools(client)

    assert Client.call_tool(client, "weather", %{"region" => "east"}) ==
             {:ok, %{"content" => [], "resultType" => "complete"}}

    assert Agent.get(state, & &1) == 2
  end

  test "default SSE server errors are delivered to the SDK HTTP client" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "region" => %{"type" => "string", "x-mcp-header" => "Zone"}
      }
    }

    plug_opts = MCPPlug.init(server_mod: StatelessHandler, tool_schemas: %{"whoami" => schema})

    bandit =
      start_supervised!({Bandit, plug: {MCPPlug, plug_opts}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    client = start_supervised!({HTTPClient, owner: self(), url: "http://127.0.0.1:#{port}/mcp"})

    message = %{
      "jsonrpc" => "2.0",
      "id" => 77,
      "method" => "tools/call",
      "params" => %{
        "name" => "whoami",
        "arguments" => %{"region" => "east"},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    stale_descriptor = %{header: "Region", path: ["region"], type: "string"}

    assert :ok = HTTPClient.send_message(client, message, routing_headers: [stale_descriptor])
    assert_receive {:mcp_message, %{"id" => 77, "error" => error}}, 1_000
    assert error["code"] == -32_020
  end
end
