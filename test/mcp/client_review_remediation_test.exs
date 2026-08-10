defmodule MCP.ClientReviewRemediationTest do
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Server.Connection

  alias MCP.Test.{
    BlockingTransport,
    ClientReviewHTTPPlug,
    ClientReviewTransport,
    ConnectRetryTransport,
    StatelessHandler
  }

  alias MCP.Transport.StreamableHTTP.Client, as: HTTPClient
  alias MCP.Transport.StreamableHTTP.SecurityPolicy

  @legacy_version "2025-11-25"

  test "connect is serialized and cached for a legacy client" do
    {client, transport} = start_legacy_client()

    first = Task.async(fn -> Client.connect(client) end)
    second = Task.async(fn -> Client.connect(client) end)

    assert_receive {:client_review_sent, ^transport, initialize, _opts}, 1_000
    assert initialize["method"] == "initialize"
    refute_receive {:client_review_sent, ^transport, %{"method" => "initialize"}, _opts}, 50

    ClientReviewTransport.inject(transport, initialize_result(initialize["id"]))

    assert {:ok, result} = Task.await(first)
    assert {:ok, ^result} = Task.await(second)

    assert_receive {:client_review_sent, ^transport, %{"method" => "notifications/initialized"},
                    _}

    assert {:ok, ^result} = Client.connect(client)
    refute_receive {:client_review_sent, ^transport, %{"method" => "initialize"}, _opts}, 50
  end

  test "each queued connect call keeps its own timeout" do
    client =
      start_supervised!(
        {Client,
         transport: {BlockingTransport, observer: self()}, protocol_version: @legacy_version}
      )

    first = Task.async(fn -> Client.connect(client, 1_000) end)
    assert_receive {:transport_send_started, %{"method" => "initialize"}}, 1_000

    second = Task.async(fn -> Client.connect(client, 0) end)
    assert {:error, :timeout} = Task.await(second, 500)

    transport = Client.transport(client)
    BlockingTransport.release(transport, {:error, :closed})
    assert {:error, :closed} = Task.await(first, 1_000)
  end

  test "a longer queued connect continues after the leader times out" do
    client =
      start_supervised!(
        {Client,
         transport: {ConnectRetryTransport, observer: self()}, protocol_version: @legacy_version}
      )

    first = Task.async(fn -> Client.connect(client, 25) end)
    assert_receive {:connect_retry_sent, 1, %{"method" => "initialize"}}, 1_000
    second = Task.async(fn -> Client.connect(client, 1_000) end)

    assert {:error, :timeout} = Task.await(first, 500)
    assert_receive {:connect_retry_sent, 2, initialize}, 1_000

    transport = Client.transport(client)
    ConnectRetryTransport.inject(transport, initialize_result(initialize["id"]))
    assert {:ok, %{protocol_version: @legacy_version}} = Task.await(second, 1_000)
  end

  test "legacy operations require a completed initialize and roots notification reports failures" do
    {client, transport} = start_legacy_client()

    assert {:error, :not_ready} = Client.ping(client)
    assert {:error, :not_ready} = Client.list_tools(client)
    assert {:error, :not_ready} = Client.notify_roots_changed(client)

    connect_legacy(client, transport)
    :ok = ClientReviewTransport.fail_next(transport, "notifications/roots/list_changed", :offline)
    assert {:error, :offline} = Client.notify_roots_changed(client)
  end

  test "failed initialized notification rolls legacy readiness back" do
    {client, transport} = start_legacy_client()
    :ok = ClientReviewTransport.fail_next(transport, "notifications/initialized", :offline)

    connect = Task.async(fn -> Client.connect(client) end)
    assert_receive {:client_review_sent, ^transport, initialize, _}, 1_000
    ClientReviewTransport.inject(transport, initialize_result(initialize["id"]))

    assert {:error, {:initialized_notification_failed, :offline}} = Task.await(connect)
    assert {:error, :not_ready} = Client.ping(client)
  end

  test "request handlers and advertised callback capabilities must agree" do
    assert {:error, {:invalid_request_handlers, _reason}} =
             Client.start_link(
               transport: {ClientReviewTransport, observer: self()},
               request_handlers: %{"roots/list" => :not_a_function}
             )

    assert {:error, {:callback_capability_mismatch, "sampling/createMessage"}} =
             Client.start_link(
               transport: {ClientReviewTransport, observer: self()},
               protocol_version: @legacy_version,
               client_capabilities: %{"sampling" => %{}}
             )
  end

  test "server request callbacks are bounded and timeout with correlated errors" do
    test_pid = self()

    {client, transport} =
      start_legacy_client(
        on_sampling: fn _params ->
          send(test_pid, {:sampling_started, self()})
          receive do: (:release -> {:ok, %{}})
        end,
        server_request_concurrency: 1,
        server_request_timeout: 75
      )

    connect_legacy(client, transport)

    ClientReviewTransport.inject(transport, server_request(41))
    assert_receive {:sampling_started, _callback}
    ClientReviewTransport.inject(transport, server_request(42))

    assert_receive {:client_review_sent, ^transport, %{"id" => 42, "error" => overload}, _}, 500
    assert overload["code"] == -32_603

    assert_receive {:client_review_sent, ^transport, %{"id" => 41, "error" => timeout}, _}, 500
    assert timeout["code"] == -32_603
  end

  test "an expired legacy session is reinitialized once and the request is retried" do
    {client, transport} = start_legacy_client()
    connect_legacy(client, transport)
    :ok = ClientReviewTransport.fail_next(transport, "tools/list", :session_expired)

    call = Task.async(fn -> Client.list_tools(client) end)
    assert_receive {:client_review_sent, ^transport, %{"method" => "tools/list"}, _}
    assert_receive {:client_review_sent, ^transport, reinitialize, _}
    assert reinitialize["method"] == "initialize"

    ClientReviewTransport.inject(transport, initialize_result(reinitialize["id"]))

    assert_receive {:client_review_sent, ^transport, %{"method" => "notifications/initialized"},
                    _}

    assert_receive {:client_review_sent, ^transport, retry, _}
    assert retry["method"] == "tools/list"

    ClientReviewTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => retry["id"],
      "result" => %{"tools" => []}
    })

    assert {:ok, %{"tools" => []}} = Task.await(call)
  end

  test "HTTP 400 JSON-RPC -32022 response drives legacy downgrade" do
    %{url: url} = start_http_plug(downgrade?: true)

    client =
      start_supervised!(
        {Client, transport: {HTTPClient, url: url}, client_info: %{name: "review", version: "1"}}
      )

    assert {:ok, %{protocol_version: @legacy_version}} = Client.connect(client)
  end

  test "HTTP 404 session expiry reinitializes once and retries the request" do
    recovery_agent = start_supervised!({Agent, fn -> %{} end})
    %{url: url} = start_http_plug(recovery: :once, recovery_agent: recovery_agent)

    client =
      start_supervised!(
        {Client,
         transport: {HTTPClient, url: url, protocol_version: @legacy_version},
         protocol_version: @legacy_version,
         client_info: %{name: "review", version: "1"}}
      )

    assert {:ok, _result} = Client.connect(client)
    assert {:ok, %{"tools" => []}} = Client.list_tools(client)
    assert Agent.get(recovery_agent, & &1) == %{initializes: 2, tools: 2}
  end

  test "HTTP 404 recovery is bounded to one reinitialize attempt" do
    recovery_agent = start_supervised!({Agent, fn -> %{} end})
    %{url: url} = start_http_plug(recovery: :always, recovery_agent: recovery_agent)

    client =
      start_supervised!(
        {Client,
         transport: {HTTPClient, url: url, protocol_version: @legacy_version},
         protocol_version: @legacy_version,
         client_info: %{name: "review", version: "1"}}
      )

    assert {:ok, _result} = Client.connect(client)
    assert {:error, :session_expired} = Client.list_tools(client)
    assert Agent.get(recovery_agent, & &1) == %{initializes: 2, tools: 2}
  end

  test "only initialize responses can bind an HTTP session" do
    %{url: url} = start_http_plug(bind_non_initialize?: true)
    client = start_supervised!({HTTPClient, owner: self(), url: url})

    first = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}
    assert :ok = HTTPClient.send_message(client, first)
    assert_receive {:mcp_message, %{"id" => 1}}

    second = %{"jsonrpc" => "2.0", "method" => "notifications/progress"}
    assert :ok = HTTPClient.send_message(client, second)
    assert_receive {:client_review_http_post, headers, ^second}
    refute Enum.any?(headers, &match?({"mcp-session-id", _}, &1))
  end

  test "legacy SSE is delivered incrementally before the response closes" do
    %{url: url} = start_http_plug(stream?: true)
    client = start_supervised!({HTTPClient, owner: self(), url: url})
    initialize = initialize_request(1)

    assert :ok = HTTPClient.send_message(client, initialize)
    assert_receive {:mcp_message, %{"id" => 1}}
    assert_receive {:client_review_stream_chunked, stream_request}
    assert_receive {:mcp_message, %{"method" => "notifications/progress"}}, 500
    assert {:message_queue_len, queue_len} = Process.info(client, :message_queue_len)
    assert queue_len <= 1
    send(stream_request, :release_stream)
  end

  test "explicit close waits for bounded session DELETE completion" do
    %{url: url} = start_http_plug()
    client = start_supervised!({HTTPClient, owner: self(), url: url})

    assert :ok = HTTPClient.send_message(client, initialize_request(1))
    assert_receive {:mcp_message, %{"id" => 1}}

    close = Task.async(fn -> HTTPClient.close(client) end)
    assert_receive {:client_review_delete, request}, 500
    send(request, :release_delete)
    assert :ok = Task.await(close, 1_000)
  end

  test "legacy SSE retry exhaustion is reported to the owner" do
    %{url: url} = start_http_plug(legacy_get_status: 500)

    client =
      start_supervised!(
        {HTTPClient,
         owner: self(), url: url, legacy_sse_retry_limit: 0, protocol_version: @legacy_version}
      )

    assert :ok = HTTPClient.send_message(client, initialize_request(1))
    assert_receive {:mcp_message, %{"id" => 1}}

    assert_receive {:mcp_legacy_sse_failed, {:retry_exhausted, {:error, {:http_status, 500}}}},
                   1_000
  end

  test "legacy GET SSE enforces the configured event bound" do
    body = "data: " <> String.duplicate("x", 80) <> "\n\n"
    %{url: url} = start_http_plug(stream?: true, stream_body: body)
    {:ok, policy} = SecurityPolicy.new(max_sse_event_bytes: 32)

    client =
      start_supervised!(
        {HTTPClient, owner: self(), url: url, security_policy: policy, legacy_sse_retry_limit: 0}
      )

    assert :ok = HTTPClient.send_message(client, initialize_request(1))
    assert_receive {:mcp_message, %{"id" => 1}}

    assert_receive {:mcp_legacy_sse_failed, {:retry_exhausted, {:error, :event_too_large}}},
                   5_000
  end

  test "subscription POST SSE enforces the configured event bound" do
    body = "data: " <> String.duplicate("x", 80) <> "\n\n"
    %{url: url} = start_http_plug(subscription_body: body)
    {:ok, policy} = SecurityPolicy.new(max_sse_event_bytes: 32)
    client = start_supervised!({HTTPClient, owner: self(), url: url, security_policy: policy})

    message = %{
      "jsonrpc" => "2.0",
      "id" => 9,
      "method" => "subscriptions/listen",
      "params" => %{}
    }

    assert :ok = HTTPClient.open_subscription(client, message)
    assert_receive {:mcp_subscription_transport_closed, 9, {:error, :event_too_large}}, 5_000
  end

  test "close APIs do not report success for the wrong process" do
    assert {:error, {:close_failed, _reason}} = Client.close(self())
    assert {:error, {:close_failed, _reason}} = HTTPClient.close(self())
    assert {:error, {:close_failed, _reason}} = Connection.close(self())
  end

  test "client and server close propagate transport close failures" do
    client =
      start_supervised!(
        {Client,
         transport: {ClientReviewTransport, observer: self(), close_error: :shutdown_failed}},
        restart: :temporary
      )

    assert {:error, {:close_failed, {:exit, {:transport_close_failed, :shutdown_failed}}}} =
             Client.close(client)

    server =
      start_supervised!(
        {Connection,
         transport: {ClientReviewTransport, observer: self(), close_error: :shutdown_failed},
         handler: {StatelessHandler, []}},
        restart: :temporary
      )

    assert {:error, {:close_failed, {:exit, {:transport_close_failed, :shutdown_failed}}}} =
             Connection.close(server)
  end

  defp start_legacy_client(opts \\ []) do
    client =
      start_supervised!(
        {Client,
         [
           transport: {ClientReviewTransport, observer: self()},
           protocol_version: @legacy_version,
           client_info: %{name: "review", version: "1"}
         ] ++ opts}
      )

    {client, Client.transport(client)}
  end

  defp connect_legacy(client, transport) do
    connect = Task.async(fn -> Client.connect(client) end)
    assert_receive {:client_review_sent, ^transport, initialize, _}, 1_000
    ClientReviewTransport.inject(transport, initialize_result(initialize["id"]))
    assert {:ok, _result} = Task.await(connect)

    assert_receive {:client_review_sent, ^transport, %{"method" => "notifications/initialized"},
                    _}
  end

  defp initialize_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @legacy_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "review", "version" => "1"}
      }
    }
  end

  defp initialize_result(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => @legacy_version,
        "capabilities" => %{},
        "serverInfo" => %{"name" => "review", "version" => "1"}
      }
    }
  end

  defp server_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "sampling/createMessage",
      "params" => %{"messages" => []}
    }
  end

  defp start_http_plug(opts \\ []) do
    bandit =
      start_supervised!(
        {Bandit,
         plug: {ClientReviewHTTPPlug, [test_pid: self()] ++ opts}, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    %{url: "http://127.0.0.1:#{port}/mcp"}
  end
end
