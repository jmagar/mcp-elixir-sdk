defmodule MCP.TriVersionCompatibilityTest do
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Protocol
  alias MCP.Server.Connection
  alias MCP.Test.{BridgeTransport, MockTransport, StatelessHandler}

  @modern "2026-07-28"
  @november "2025-11-25"
  @june "2025-06-18"

  test "advertises all revisions newest first" do
    assert Protocol.supported_versions() == [@modern, @november, @june]
  end

  test "an explicitly configured 2025-06-18 client initializes that revision" do
    {:ok, client} =
      start_supervised(
        {Client,
         transport: {MockTransport, []},
         protocol_version: @june,
         client_info: %{name: "june-client", version: "1.0.0"}}
      )

    transport = Client.transport(client)
    connect = Task.async(fn -> Client.connect(client) end)
    {:ok, [initialize]} = MockTransport.await_sent(transport, 1)

    assert initialize["method"] == "initialize"
    assert initialize["params"]["protocolVersion"] == @june

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => initialize["id"],
      "result" => %{
        "protocolVersion" => @june,
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "june-server", "version" => "1.0.0"}
      }
    })

    assert {:ok, %{protocol_version: @june}} = Task.await(connect)
  end

  test "automatic negotiation selects 2025-06-18 when it is the only supported revision" do
    {:ok, client} =
      start_supervised(
        {Client,
         transport: {MockTransport, []}, client_info: %{name: "auto-client", version: "1.0.0"}}
      )

    transport = Client.transport(client)
    connect = Task.async(fn -> Client.connect(client) end)
    {:ok, [discover]} = MockTransport.await_sent(transport, 1)

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => discover["id"],
      "error" => %{
        "code" => -32_022,
        "message" => "Unsupported protocol version",
        "data" => %{"supported" => [@june]}
      }
    })

    {:ok, [_discover, initialize]} = MockTransport.await_sent(transport, 2)
    assert initialize["params"]["protocolVersion"] == @june

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => initialize["id"],
      "result" => %{
        "protocolVersion" => @june,
        "capabilities" => %{},
        "serverInfo" => %{"name" => "june-server", "version" => "1.0.0"}
      }
    })

    assert {:ok, %{protocol_version: @june}} = Task.await(connect)
  end

  test "an initialize result cannot switch legacy revisions" do
    {:ok, client} =
      start_supervised(
        {Client,
         transport: {MockTransport, []},
         protocol_version: @june,
         client_info: %{name: "june-client", version: "1.0.0"}}
      )

    transport = Client.transport(client)
    connect = Task.async(fn -> Client.connect(client) end)
    {:ok, [initialize]} = MockTransport.await_sent(transport, 1)

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => initialize["id"],
      "result" => %{
        "protocolVersion" => @november,
        "capabilities" => %{},
        "serverInfo" => %{"name" => "wrong-server", "version" => "1.0.0"}
      }
    })

    assert {:error, {:invalid_initialize_result, {:unsupported_protocol_version, @november}}} =
             Task.await(connect)
  end

  test "the owner-based server accepts a 2025-06-18 initialization" do
    {client_transport, server_transport} = BridgeTransport.create_pair()

    {:ok, _server} =
      start_supervised(
        {Connection,
         transport: {BridgeTransport, pid: server_transport},
         handler: {StatelessHandler, []},
         server_info: %{name: "tri-version-server", version: "2.0.0"}}
      )

    assert {:ok, _transport} = BridgeTransport.start_link(pid: client_transport, owner: self())

    :ok =
      BridgeTransport.send_message(client_transport, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => @june,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "june-client", "version" => "1.0.0"}
        }
      })

    assert_receive {:mcp_message, response}, 1_000
    assert response["result"]["protocolVersion"] == @june
  end
end
