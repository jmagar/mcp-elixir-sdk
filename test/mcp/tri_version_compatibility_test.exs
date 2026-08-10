defmodule MCP.TriVersionCompatibilityTest do
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Protocol
  alias MCP.Protocol.Legacy.V2025_06_18
  alias MCP.Server.Connection
  alias MCP.Test.{BridgeTransport, MockTransport, StatelessHandler}
  alias MCP.Transport.StreamableHTTP.Plug, as: MCPPlug

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

  test "method-not-found negotiation falls through November rejection to June" do
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
      "error" => %{"code" => -32_022, "message" => "Unsupported protocol version"}
    })

    {:ok, [_discover, _november, june]} = MockTransport.await_sent(transport, 3)
    assert june["params"]["protocolVersion"] == @june

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => june["id"],
      "result" => %{
        "protocolVersion" => @june,
        "capabilities" => %{},
        "serverInfo" => %{"name" => "june-server", "version" => "1.0.0"}
      }
    })

    assert {:ok, %{protocol_version: @june}} = Task.await(connect)
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

    # Anything other than the unsupported-version code is a real failure. It must
    # not be swallowed and re-reported as a malformed initialize result, and it
    # must not advance the fallback ladder.
    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => november["id"],
      "error" => %{"code" => -32_001, "message" => "Unauthorized"}
    })

    assert {:error, %MCP.Protocol.Error{code: -32_001, message: "Unauthorized"}} =
             Task.await(connect)

    assert {:ok, [_discover, _november]} = MockTransport.await_sent(transport, 2)
  end

  test "June capability projection removes features introduced in November" do
    capabilities = %{
      "tasks" => %{"list" => %{}},
      "elicitation" => %{"form" => %{}, "url" => %{}},
      "tools" => %{}
    }

    assert V2025_06_18.project_capabilities(capabilities) == %{
             "elicitation" => %{"form" => %{}},
             "tools" => %{}
           }
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

    assert_receive {:mcp_message, response}, 5_000
    assert response["result"]["protocolVersion"] == @june
  end

  test "an HTTP legacy session negotiated at 2025-06-18 binds that revision to every verb" do
    config =
      MCPPlug.init(
        server_mod: StatelessHandler,
        server_opts: [server_info: %{name: "june-http", version: "2.0.0"}],
        enable_json_response: true
      )

    initialize =
      june_post(config, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => @june,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "june-http-client", "version" => "1.0.0"}
        }
      })

    assert initialize.status == 200
    [session_id] = Plug.Conn.get_resp_header(initialize, "mcp-session-id")
    assert Jason.decode!(initialize.resp_body)["result"]["protocolVersion"] == @june

    assert june_post(
             config,
             %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
             session_id
           ).status == 202

    tools =
      june_post(
        config,
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}},
        session_id
      )

    assert tools.status == 200

    assert Enum.any?(
             get_in(Jason.decode!(tools.resp_body), ["result", "tools"]),
             &(&1["name"] == "whoami")
           )

    # A follow-up POST presenting the other legacy revision must not be accepted
    # onto a session negotiated at 2025-06-18.
    mismatched =
      config
      |> legacy_conn(:post, %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list"}, @november)
      |> Plug.Conn.put_req_header("mcp-session-id", session_id)
      |> MCPPlug.call(config)

    assert mismatched.status == 400
    assert Jason.decode!(mismatched.resp_body)["error"]["code"] == -32_022

    get =
      config
      |> legacy_conn(:get, nil, @june)
      |> Plug.Conn.put_req_header("accept", "text/event-stream")
      |> Plug.Conn.put_req_header("mcp-session-id", session_id)
      |> MCPPlug.call(config)

    assert get.status in [200, 405]

    mismatched_delete =
      config
      |> legacy_conn(:delete, nil, @november)
      |> Plug.Conn.put_req_header("mcp-session-id", session_id)
      |> MCPPlug.call(config)

    assert mismatched_delete.status == 400
    assert MCPPlug.legacy_sessions(config) != []

    delete =
      config
      |> legacy_conn(:delete, nil, @june)
      |> Plug.Conn.put_req_header("mcp-session-id", session_id)
      |> MCPPlug.call(config)

    assert delete.status in [200, 204]
    assert MCPPlug.legacy_sessions(config) == []
  end

  defp june_post(config, message, session_id \\ nil) do
    conn = legacy_conn(config, :post, message, @june)

    conn =
      if session_id,
        do: Plug.Conn.put_req_header(conn, "mcp-session-id", session_id),
        else: conn

    MCPPlug.call(conn, config)
  end

  defp legacy_conn(_config, method, message, version) do
    body = if message, do: Jason.encode!(message), else: ""

    conn =
      method
      |> Plug.Test.conn("http://localhost/mcp", body)
      |> Plug.Conn.put_req_header("origin", "http://localhost")
      |> Plug.Conn.put_req_header("mcp-protocol-version", version)

    if message do
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")
    else
      conn
    end
  end
end
