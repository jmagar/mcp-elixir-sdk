defmodule MCP.DualProtocolCompatibilityTest do
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Protocol
  alias MCP.Server.Connection

  alias MCP.Test.{
    BridgeTransport,
    LegacyFeatureHandler,
    LegacySessionCapturePlug,
    MockTransport,
    StatelessHandler
  }

  alias MCP.Transport.StreamableHTTP.LegacySession
  alias MCP.Transport.StreamableHTTP.Plug, as: MCPPlug

  @legacy_version "2025-11-25"
  @older_legacy_version "2025-06-18"
  @stateless_version "2026-07-28"

  test "the SDK advertises both supported protocol eras in preference order" do
    assert Protocol.supported_versions() == [
             @stateless_version,
             @legacy_version,
             @older_legacy_version
           ]

    assert Protocol.protocol_version() == @stateless_version
  end

  test "client negotiates down to 2025-11-25 and uses the legacy handshake" do
    {:ok, client} =
      start_supervised(
        {Client,
         transport: {MockTransport, []}, client_info: %{name: "compat-client", version: "1.0.0"}}
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
        "data" => %{"supported" => [@legacy_version]}
      }
    })

    {:ok, [_discover, initialize]} = MockTransport.await_sent(transport, 2)
    assert initialize["method"] == "initialize"
    assert initialize["params"]["protocolVersion"] == @legacy_version
    refute Map.has_key?(initialize["params"], "_meta")

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => initialize["id"],
      "result" => %{
        "protocolVersion" => @legacy_version,
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "legacy-server", "version" => "1.0.0"}
      }
    })

    assert {:ok, %{protocol_version: @legacy_version}} = Task.await(connect)
    [_discover, _initialize, initialized] = MockTransport.sent_messages(transport)

    assert initialized == %{
             "jsonrpc" => "2.0",
             "method" => "notifications/initialized"
           }

    list_tools = Task.async(fn -> Client.list_tools(client) end)
    {:ok, messages} = MockTransport.await_sent(transport, 4)
    request = List.last(messages)
    assert request["method"] == "tools/list"
    refute Map.has_key?(request["params"], "_meta")

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => request["id"],
      "result" => %{"tools" => []}
    })

    assert {:ok, %{"tools" => []}} = Task.await(list_tools)
  end

  test "one server connection accepts a 2025 client handshake and legacy request shapes" do
    {client_transport, server_transport} = BridgeTransport.create_pair()

    {:ok, server} =
      start_supervised(
        {Connection,
         transport: {BridgeTransport, pid: server_transport},
         handler: {StatelessHandler, []},
         server_info: %{name: "dual-server", version: "2.0.0"}}
      )

    :ok = BridgeTransport.start_link(pid: client_transport, owner: self()) |> elem(0)

    :ok =
      BridgeTransport.send_message(client_transport, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => @legacy_version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "old-client", "version" => "1.0.0"}
        }
      })

    assert_receive {:mcp_message, initialize_response}, 1_000
    assert initialize_response["result"]["protocolVersion"] == @legacy_version
    assert initialize_response["result"]["serverInfo"]["name"] == "dual-server"

    :ok =
      BridgeTransport.send_message(client_transport, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

    _ = :sys.get_state(server)

    :ok =
      BridgeTransport.send_message(client_transport, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/list",
        "params" => %{}
      })

    assert_receive {:mcp_message, tools_response}, 1_000

    assert [%{"name" => "whoami"}] =
             Enum.map(tools_response["result"]["tools"], &Map.take(&1, ["name"]))

    refute Map.has_key?(tools_response["result"], "resultType")

    :ok =
      BridgeTransport.send_message(client_transport, %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "server/discover",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @stateless_version,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      })

    assert_receive {:mcp_message, mixed_mode_response}, 1_000
    assert mixed_mode_response["error"]["code"] == -32_600
    assert mixed_mode_response["error"]["message"] == "Invalid request"
  end

  test "one HTTP endpoint maintains a 2025 session while retaining the 2026 path" do
    config =
      MCPPlug.init(
        server_mod: StatelessHandler,
        server_opts: [server_info: %{name: "dual-http", version: "2.0.0"}],
        enable_json_response: true
      )

    initialize =
      legacy_http_post(config, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => @legacy_version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "old-http", "version" => "1.0.0"}
        }
      })

    assert initialize.status == 200
    [session_id] = Plug.Conn.get_resp_header(initialize, "mcp-session-id")
    assert Jason.decode!(initialize.resp_body)["result"]["protocolVersion"] == @legacy_version

    initialized =
      legacy_http_post(
        config,
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        session_id
      )

    assert initialized.status == 202

    tools =
      legacy_http_post(
        config,
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}},
        session_id
      )

    assert tools.status == 200

    assert [%{"name" => "whoami"}] =
             tools.resp_body
             |> Jason.decode!()
             |> get_in(["result", "tools"])
             |> Enum.map(&Map.take(&1, ["name"]))

    stateless = %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "server/discover",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @stateless_version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    conn =
      :post
      |> Plug.Test.conn("http://localhost/mcp", Jason.encode!(stateless))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("origin", "http://localhost")
      |> Plug.Conn.put_req_header("mcp-protocol-version", @stateless_version)
      |> Plug.Conn.put_req_header("mcp-method", "server/discover")
      |> MCPPlug.call(config)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["result"]["supportedVersions"] == [@stateless_version]

    wrong_version =
      :post
      |> Plug.Test.conn(
        "http://localhost/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 4, "method" => "tools/list"})
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("origin", "http://localhost")
      |> Plug.Conn.put_req_header("mcp-session-id", session_id)
      |> Plug.Conn.put_req_header("mcp-protocol-version", @stateless_version)
      |> MCPPlug.call(config)

    assert wrong_version.status == 400
    assert Jason.decode!(wrong_version.resp_body)["error"]["code"] == -32_022
  end

  test "the SDK client completes a 2025 session over real Streamable HTTP" do
    plug =
      MCPPlug.new(
        server_mod: StatelessHandler,
        server_opts: [server_info: %{name: "legacy-http-server", version: "2.0.0"}],
        enable_json_response: true
      )

    bandit =
      start_supervised!(
        {Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0},
        id: :legacy_compat_bandit
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      start_supervised!(
        {Client,
         transport:
           {MCP.Transport.StreamableHTTP.Client,
            url: "http://127.0.0.1:#{port}/mcp", protocol_version: @legacy_version},
         protocol_version: @legacy_version,
         client_info: %{name: "legacy-sdk-client", version: "2.0.0"}},
        id: :legacy_compat_client
      )

    assert {:ok, %{protocol_version: @legacy_version}} = Client.connect(client)
    assert {:ok, %{"tools" => tools}} = Client.list_tools(client)
    assert Enum.any?(tools, &(&1["name"] == "whoami"))
  end

  test "default HTTP client falls back from discovery to a legacy server session" do
    bandit =
      start_supervised!(
        {Bandit, plug: {LegacySessionCapturePlug, test_pid: self()}, ip: {127, 0, 0, 1}, port: 0},
        id: :legacy_fallback_bandit
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      start_supervised!(
        {Client,
         transport: {MCP.Transport.StreamableHTTP.Client, url: "http://127.0.0.1:#{port}/mcp"},
         client_info: %{name: "auto-client", version: "2.0.0"}},
        id: :legacy_fallback_client
      )

    assert {:ok, %{protocol_version: @legacy_version}} = Client.connect(client)

    assert_receive {:legacy_captured_request, discover_headers, %{"method" => "server/discover"}}

    assert_receive {:legacy_captured_request, initialize_headers, %{"method" => "initialize"}}

    assert Enum.any?(discover_headers, &match?({"mcp-protocol-version", @stateless_version}, &1))
    assert Enum.any?(initialize_headers, &match?({"mcp-protocol-version", @legacy_version}, &1))

    assert_receive {:legacy_captured_request, initialized_headers,
                    %{"method" => "notifications/initialized"}}

    assert Enum.any?(initialized_headers, &match?({"mcp-session-id", "legacy-session"}, &1))
  end

  test "2025 client exposes legacy ping, resource subscriptions, and server requests" do
    test_pid = self()

    {:ok, client} =
      start_supervised(
        {Client,
         transport: {MockTransport, []},
         protocol_version: @legacy_version,
         client_info: %{name: "full-legacy-client", version: "2.0.0"},
         on_sampling: fn params ->
           send(test_pid, {:sampling_called, params})

           {:ok,
            %{
              "role" => "assistant",
              "content" => %{"type" => "text", "text" => "sampled"},
              "model" => "test",
              "stopReason" => "endTurn"
            }}
         end}
      )

    transport = Client.transport(client)
    connect = Task.async(fn -> Client.connect(client) end)
    {:ok, [initialize]} = MockTransport.await_sent(transport, 1, 5_000)

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => initialize["id"],
      "result" => %{
        "protocolVersion" => @legacy_version,
        "capabilities" => %{"resources" => %{"subscribe" => true}},
        "serverInfo" => %{"name" => "legacy-server", "version" => "1.0.0"}
      }
    })

    assert {:ok, _result} = Task.await(connect)

    for {operation, expected_method} <- [
          {fn -> Client.ping(client) end, "ping"},
          {fn -> Client.subscribe_resource(client, "file:///events") end, "resources/subscribe"},
          {fn -> Client.unsubscribe_resource(client, "file:///events") end,
           "resources/unsubscribe"}
        ] do
      previous_count = length(MockTransport.sent_messages(transport))
      request = Task.async(operation)
      {:ok, messages} = MockTransport.await_sent(transport, previous_count + 1)
      sent = List.last(messages)
      assert sent["method"] == expected_method

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => sent["id"],
        "result" => %{}
      })

      assert {:ok, %{}} = Task.await(request)
    end

    previous_count = length(MockTransport.sent_messages(transport))

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => 99,
      "method" => "sampling/createMessage",
      "params" => %{"messages" => []}
    })

    assert_receive {:sampling_called, %{"messages" => []}}
    {:ok, messages} = MockTransport.await_sent(transport, previous_count + 1)
    response = Enum.find(messages, &(&1["id"] == 99))
    assert response
    assert response["id"] == 99
    assert response["result"]["model"] == "test"

    assert {:error, :stateless_protocol_required} =
             Client.listen_subscriptions(client, %MCP.Protocol.Types.SubscriptionFilter{})
  end

  test "2025 server can issue sampling requests to a negotiated legacy client" do
    {client_transport, server_transport} = BridgeTransport.create_pair()

    {:ok, server} =
      start_supervised(
        {Connection,
         transport: {BridgeTransport, pid: server_transport},
         handler: {StatelessHandler, []},
         server_info: %{name: "requesting-server", version: "2.0.0"}}
      )

    {:ok, client} =
      start_supervised(
        {Client,
         transport: {BridgeTransport, pid: client_transport},
         protocol_version: @legacy_version,
         client_info: %{name: "sampling-client", version: "2.0.0"},
         notification_handler: self(),
         on_sampling: fn _params ->
           {:ok,
            %{
              "role" => "assistant",
              "content" => %{"type" => "text", "text" => "from client"},
              "model" => "test-model",
              "stopReason" => "endTurn"
            }}
         end}
      )

    assert {:ok, %{protocol_version: @legacy_version}} = Client.connect(client)
    _ = :sys.get_state(server)

    assert {:ok, %{"model" => "test-model"}} =
             Connection.request_sampling(server, %{"messages" => []})

    Connection.notify_tools_changed(server)
    assert_receive {:mcp_notification, "notifications/tools/list_changed", nil}
  end

  test "2025 HTTP sessions dispatch legacy resource subscriptions and logging callbacks" do
    config =
      MCPPlug.init(
        server_mod: LegacyFeatureHandler,
        handler_opts: [test_pid: self(), identity: :bound_identity],
        enable_json_response: true
      )

    initialize =
      legacy_http_post(config, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => @legacy_version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "legacy-features", "version" => "1.0.0"}
        }
      })

    [session_id] = Plug.Conn.get_resp_header(initialize, "mcp-session-id")

    assert 202 ==
             legacy_http_post(
               config,
               %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
               session_id
             ).status

    for {id, method, params, expected} <- [
          {2, "resources/subscribe", %{"uri" => "file:///events"},
           {:subscribed, "file:///events", :bound_identity}},
          {3, "resources/unsubscribe", %{"uri" => "file:///events"},
           {:unsubscribed, "file:///events", :bound_identity}},
          {4, "logging/setLevel", %{"level" => "warning"},
           {:log_level, "warning", :bound_identity}}
        ] do
      response =
        legacy_http_post(
          config,
          %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params},
          session_id
        )

      assert response.status == 200
      assert Jason.decode!(response.resp_body)["result"] == %{}
      assert_receive ^expected
    end
  end

  test "2025 HTTP server can send a sampling request over the session SSE channel" do
    config =
      MCPPlug.init(
        server_mod: StatelessHandler,
        server_opts: [server_info: %{name: "http-requesting-server", version: "2.0.0"}],
        enable_json_response: true,
        legacy_sse_timeout: 500
      )

    bandit =
      start_supervised!(
        {Bandit, plug: {MCPPlug, config}, ip: {127, 0, 0, 1}, port: 0},
        id: :legacy_server_request_bandit
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      start_supervised!(
        {Client,
         transport:
           {MCP.Transport.StreamableHTTP.Client,
            url: "http://127.0.0.1:#{port}/mcp", protocol_version: @legacy_version},
         protocol_version: @legacy_version,
         client_info: %{name: "http-sampling-client", version: "2.0.0"},
         on_sampling: fn _params ->
           {:ok,
            %{
              "role" => "assistant",
              "content" => %{"type" => "text", "text" => "over SSE"},
              "model" => "http-test-model",
              "stopReason" => "endTurn"
            }}
         end},
        id: :legacy_server_request_client
      )

    assert {:ok, %{protocol_version: @legacy_version}} = Client.connect(client)
    [{_session_id, server}] = MCPPlug.legacy_sessions(config)

    assert {:ok, %{"model" => "http-test-model"}} =
             Connection.request_sampling(server, %{"messages" => []}, 5_000)
  end

  test "2025 HTTP sessions bound their unconsumed SSE event queue" do
    config =
      MCPPlug.init(
        server_mod: StatelessHandler,
        server_opts: [server_info: %{name: "bounded-server", version: "2.0.0"}],
        enable_json_response: true
      )

    initialize =
      legacy_http_post(config, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => @legacy_version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "non-reading-client", "version" => "1.0.0"}
        }
      })

    [session_id] = Plug.Conn.get_resp_header(initialize, "mcp-session-id")
    [{^session_id, server}] = MCPPlug.legacy_sessions(config)
    transport = :sys.get_state(server).transport_pid
    on_exit(fn -> Connection.close(server) end)

    notification = %{"jsonrpc" => "2.0", "method" => "notifications/message", "params" => %{}}

    for _index <- 1..256 do
      assert :ok = LegacySession.send_message(transport, notification)
    end

    assert {:error, :queue_overflow} =
             LegacySession.send_message(transport, notification)
  end

  defp legacy_http_post(config, message, session_id \\ nil) do
    conn =
      :post
      |> Plug.Test.conn("http://localhost/mcp", Jason.encode!(message))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("origin", "http://localhost")
      |> Plug.Conn.put_req_header("mcp-protocol-version", @legacy_version)

    conn =
      if session_id,
        do: Plug.Conn.put_req_header(conn, "mcp-session-id", session_id),
        else: conn

    MCPPlug.call(conn, config)
  end
end
