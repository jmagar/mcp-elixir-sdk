defmodule MCP.DualVersionSecurityCompatibilityTest do
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Protocol
  alias MCP.Test.MockTransport

  @modern "2026-07-28"
  @november "2025-11-25"

  test "advertises only the stateless and November revisions newest first" do
    assert Protocol.supported_versions() == [@modern, @november]
  end

  test "an explicitly configured June revision is rejected at startup" do
    assert {:error, {:unsupported_protocol_version, "2025-06-18"}} =
             GenServer.start(Client,
               transport: {MockTransport, []},
               protocol_version: "2025-06-18",
               client_info: %{name: "unsupported-client", version: "1.0.0"}
             )
  end

  test "a non-version error during fallback initialize reaches the caller unchanged" do
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
      "error" => %{"code" => -32_601, "message" => "Method not found"}
    })

    {:ok, [_discover, november]} = MockTransport.await_sent(transport, 2)
    assert november["params"]["protocolVersion"] == @november

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => november["id"],
      "error" => %{"code" => -32_001, "message" => "Unauthorized"}
    })

    assert {:error, %MCP.Protocol.Error{code: -32_001, message: "Unauthorized"}} =
             Task.await(connect)

    assert {:ok, [_discover, _november]} = MockTransport.await_sent(transport, 2)
  end

  test "an initialize result cannot switch from November to the modern revision" do
    {:ok, client} =
      start_supervised(
        {Client,
         transport: {MockTransport, []},
         protocol_version: @november,
         client_info: %{name: "november-client", version: "1.0.0"}}
      )

    transport = Client.transport(client)
    connect = Task.async(fn -> Client.connect(client) end)
    {:ok, [initialize]} = MockTransport.await_sent(transport, 1)

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => initialize["id"],
      "result" => %{
        "protocolVersion" => @modern,
        "capabilities" => %{},
        "serverInfo" => %{"name" => "wrong-server", "version" => "1.0.0"}
      }
    })

    assert {:error, {:invalid_initialize_result, {:unsupported_protocol_version, @modern}}} =
             Task.await(connect)
  end
end
