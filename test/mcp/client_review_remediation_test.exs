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

  @modern_version "2026-07-28"
  @legacy_version "2025-11-25"

  test "connect is serialized and cached for a legacy client" do
    {client, transport} = start_legacy_client()

    first = Task.async(fn -> Client.connect(client) end)
    second = Task.async(fn -> Client.connect(client) end)

    assert_receive {:client_review_sent, ^transport, initialize, _opts}, 5_000
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
    assert_receive {:transport_send_started, %{"method" => "initialize"}}, 5_000

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
    assert_receive {:connect_retry_sent, 1, %{"method" => "initialize"}}, 5_000
    second = Task.async(fn -> Client.connect(client, 1_000) end)

    assert {:error, :timeout} = Task.await(first, 500)
    assert_receive {:connect_retry_sent, 2, initialize}, 5_000

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
    assert_receive {:client_review_sent, ^transport, initialize, _}, 5_000
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

  test "captured stdio diagnostics require an explicit high-level client handler" do
    client =
      start_supervised!(
        {Client, transport: {ClientReviewTransport, observer: self()}, stderr_handler: self()}
      )

    send(client, {:mcp_transport_stderr, "bounded diagnostic"})
    assert_receive {:mcp_transport_stderr, "bounded diagnostic"}

    assert {:error, {:invalid_stderr_handler, :log_it}} =
             Client.start_link(
               transport: {ClientReviewTransport, observer: self()},
               stderr_handler: :log_it
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

    assert_receive {:client_review_sent, ^transport, %{"id" => 42, "error" => overload}, _}, 5_000
    assert overload["code"] == -32_603

    assert_receive {:client_review_sent, ^transport, %{"id" => 41, "error" => timeout}, _}, 5_000
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

  test "asynchronous legacy SSE expiry invalidates cached initialization" do
    {client, transport} = start_legacy_client()
    connect_legacy(client, transport)

    send(client, {:mcp_legacy_sse_failed, :session_expired})
    assert {:error, :not_ready} = Client.list_tools(client)

    reconnect = Task.async(fn -> Client.connect(client) end)
    assert_receive {:client_review_sent, ^transport, reinitialize, _}, 5_000
    assert reinitialize["method"] == "initialize"

    ClientReviewTransport.inject(transport, initialize_result(reinitialize["id"]))
    assert {:ok, _result} = Task.await(reconnect)

    assert_receive {:client_review_sent, ^transport, %{"method" => "notifications/initialized"},
                    _}
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

  test "malformed initialize response never poisons the next HTTP session" do
    recovery_agent = start_supervised!({Agent, fn -> %{} end})

    %{url: url} =
      start_http_plug(
        malformed_initialize_once?: true,
        recovery_agent: recovery_agent
      )

    transport =
      start_supervised!({HTTPClient, owner: self(), url: url, protocol_version: @legacy_version})

    assert {:error, :non_protocol_json} =
             HTTPClient.send_message(transport, initialize_request(1))

    assert_receive {:client_review_http_post, first_headers, %{"id" => 1}}
    refute List.keymember?(first_headers, "mcp-session-id", 0)
    assert :sys.get_state(transport).session_id == nil

    assert :ok = HTTPClient.send_message(transport, initialize_request(2))
    assert_receive {:client_review_http_post, second_headers, %{"id" => 2}}
    refute List.keymember?(second_headers, "mcp-session-id", 0)
  end

  test "only a matching successful initialize response can bind an HTTP session" do
    for override <- [:wrong_id, :notification, :error, :incomplete] do
      %{url: url} = start_http_plug(initialize_override: override)

      transport =
        start_supervised!(
          {HTTPClient, owner: self(), url: url, protocol_version: @legacy_version},
          id: {HTTPClient, override}
        )

      result = HTTPClient.send_message(transport, initialize_request(10))

      if override in [:error, :incomplete],
        do: assert(result == :ok),
        else: assert(result == {:error, {:mismatched_response_id, 10}})

      assert :sys.get_state(transport).session_id == nil
    end
  end

  test "a modern initialize response ignores an unexpected session header" do
    %{url: url} = start_http_plug(initialize_protocol_version: @modern_version)

    transport =
      start_supervised!({HTTPClient, owner: self(), url: url, protocol_version: @modern_version})

    assert :ok = HTTPClient.send_message(transport, initialize_request(1, @modern_version))
    assert :sys.get_state(transport).session_id == nil

    notification = %{"jsonrpc" => "2.0", "method" => "notifications/progress"}
    assert :ok = HTTPClient.send_message(transport, notification)
    assert_receive {:client_review_http_post, headers, ^notification}
    refute List.keymember?(headers, "mcp-session-id", 0)
  end

  test "an HTTP session binding is immutable until explicit reset" do
    %{url: url} = start_http_plug(stream?: true)

    transport =
      start_supervised!({HTTPClient, owner: self(), url: url, protocol_version: @legacy_version})

    assert :ok = GenServer.call(transport, {:bind_session, "first", @legacy_version})
    assert_receive {:client_review_stream_chunked, stream_request}, 5_000
    assert :ok = GenServer.call(transport, {:bind_session, "first", @legacy_version})

    assert {:error, :session_already_bound} =
             GenServer.call(transport, {:bind_session, "second", @legacy_version})

    assert :sys.get_state(transport).session_id == "first"
    send(stream_request, :release_stream)
  end

  test "truncated initialize SSE response cannot bind an HTTP session" do
    body = "data: #{Jason.encode!(initialize_result(1))}"
    %{url: url} = start_http_plug(initialize_sse_body: body)

    transport =
      start_supervised!({HTTPClient, owner: self(), url: url, protocol_version: @legacy_version})

    assert {:error, :truncated_sse_event} =
             HTTPClient.send_message(transport, initialize_request(1))

    assert :sys.get_state(transport).session_id == nil
  end

  test "HTTP policy rejects work beyond the concurrent request limit" do
    %{url: url} = start_http_plug(block_post?: true)

    transport =
      start_supervised!(
        {HTTPClient, owner: self(), url: url, security_policy: [max_concurrent_requests: 1]}
      )

    first =
      Task.async(fn ->
        HTTPClient.send_message(transport, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        })
      end)

    assert_receive {:client_review_post_blocked, request}, 5_000

    assert {:error, :request_limit_reached} =
             HTTPClient.send_message(transport, %{
               "jsonrpc" => "2.0",
               "id" => 2,
               "method" => "tools/list"
             })

    send(request, :release_post)
    assert :ok = Task.await(first)
  end

  test "HTTP policy rejects subscriptions beyond the concurrent stream limit" do
    %{url: url} = start_http_plug(block_subscription?: true)

    transport =
      start_supervised!(
        {HTTPClient, owner: self(), url: url, security_policy: [max_subscriptions: 1]}
      )

    assert :ok =
             HTTPClient.open_subscription(transport, %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "subscriptions/listen"
             })

    assert_receive {:client_review_stream_chunked, request}, 5_000

    assert {:error, :subscription_limit_reached} =
             HTTPClient.open_subscription(transport, %{
               "jsonrpc" => "2.0",
               "id" => 2,
               "method" => "subscriptions/listen"
             })

    send(request, :release_stream)
  end

  test "legacy SSE is delivered incrementally before the response closes" do
    %{url: url} = start_http_plug(stream?: true)
    client = start_supervised!({HTTPClient, owner: self(), url: url})
    initialize = initialize_request(1)

    assert :ok = HTTPClient.send_message(client, initialize)
    assert_receive {:mcp_message, %{"id" => 1}}
    assert_receive {:client_review_stream_chunked, stream_request}, 5_000
    assert_receive {:mcp_message, %{"method" => "notifications/progress"}}, 5_000
    assert {:message_queue_len, queue_len} = Process.info(client, :message_queue_len)
    assert queue_len <= 1
    send(stream_request, :release_stream)
  end

  test "explicit close waits for bounded session DELETE completion" do
    %{url: url} = start_http_plug(stream?: true)
    client = start_supervised!({HTTPClient, owner: self(), url: url})

    assert :ok = HTTPClient.send_message(client, initialize_request(1))
    assert_receive {:mcp_message, %{"id" => 1}}
    assert_receive {:client_review_stream_chunked, stream_request}, 5_000

    close = Task.async(fn -> HTTPClient.close(client) end)
    assert_receive {:client_review_delete, request}, 5_000

    # Without this the test passes under the old best-effort behaviour too: it
    # would only prove close eventually returns :ok, not that it waited for the
    # DELETE it issued.
    refute Task.yield(close, 50)

    send(request, :release_delete)
    assert :ok = Task.await(close, 1_000)
    send(stream_request, :release_stream)
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

  test "subscription POST errors enforce the stricter decoded response bound" do
    body = String.duplicate("x", 65)
    %{url: url} = start_http_plug(subscription_status: 500, subscription_body: body)

    {:ok, policy} =
      SecurityPolicy.new(max_response_bytes: 1_000, max_decoded_response_bytes: 64)

    client = start_supervised!({HTTPClient, owner: self(), url: url, security_policy: policy})

    message = %{
      "jsonrpc" => "2.0",
      "id" => 10,
      "method" => "subscriptions/listen",
      "params" => %{}
    }

    assert :ok = HTTPClient.open_subscription(client, message)

    assert_receive {:mcp_subscription_transport_closed, 10, {:error, {:response_too_large, 64}}},
                   5_000
  end

  test "client records and applies transport cleanup failure before closure" do
    {client, transport} = start_legacy_client()
    connect_legacy(client, transport)

    request = Task.async(fn -> Client.list_tools(client) end)
    assert_receive {:client_review_sent, ^transport, %{"method" => "tools/list"}, _}

    send(client, {:mcp_transport_cleanup_failed, :escaped_process})
    send(client, {:mcp_transport_closed, :normal})

    assert {:error, {:transport_closed, {:cleanup_failed, :escaped_process, :normal}}} =
             Task.await(request)

    assert Client.transport_failure(client) == :escaped_process
    assert Client.status(client) == :closed
  end

  test "close APIs do not report success for the wrong process" do
    assert {:error, {:close_failed, _reason}} = Client.close(self())
    assert {:error, {:close_failed, _reason}} = HTTPClient.close(self())
    assert {:error, {:close_failed, _reason}} = Connection.close(self())
  end

  test "HTTP clients reject malformed security policy structs" do
    policy = %SecurityPolicy{max_response_bytes: 0}
    Process.flag(:trap_exit, true)

    assert {:error, {:invalid_security_policy, {:max_response_bytes, 0}}} =
             HTTPClient.start_link(
               owner: self(),
               url: "http://127.0.0.1:1",
               security_policy: policy
             )
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
    assert_receive {:client_review_sent, ^transport, initialize, _}, 5_000
    ClientReviewTransport.inject(transport, initialize_result(initialize["id"]))
    assert {:ok, _result} = Task.await(connect)

    assert_receive {:client_review_sent, ^transport, %{"method" => "notifications/initialized"},
                    _}
  end

  defp initialize_request(id, protocol_version \\ @legacy_version) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => protocol_version,
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

  defp start_http_plug(opts) do
    bandit =
      start_supervised!(
        {Bandit,
         plug: {ClientReviewHTTPPlug, [test_pid: self()] ++ opts}, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    %{url: "http://127.0.0.1:#{port}/mcp"}
  end
end
