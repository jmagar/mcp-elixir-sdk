defmodule MCP.SubscriptionsHTTPIntegrationTest do
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Client.SubscriptionHandle
  alias MCP.Protocol.Messages.Subscriptions.ListenResult
  alias MCP.Protocol.Methods
  alias MCP.Protocol.Types.SubscriptionFilter
  alias MCP.Server.{SubscriptionPublisher, SubscriptionWorker}
  alias MCP.Test.SubscriptionHandler
  alias MCP.Transport.StreamableHTTP

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"
  @version "2026-07-28"

  setup do
    client_supervisor =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :http_client_subs)

    server_supervisor =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :http_server_subs)

    registry = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :duplicate, name: registry})

    plug =
      StreamableHTTP.Plug.new(
        server_mod: SubscriptionHandler,
        handler_opts: [test_pid: self(), identity: :http_principal],
        subscription_supervisor: server_supervisor,
        subscription_registry: registry,
        subscription_endpoint: :http_test,
        subscription_keepalive_interval: 10
      )

    bandit =
      start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    url = "http://127.0.0.1:#{port}/mcp"

    client =
      start_supervised!(
        {Client,
         transport: {StreamableHTTP.Client, url: url}, subscription_supervisor: client_supervisor}
      )

    %{client: client, registry: registry, url: url}
  end

  test "streams acknowledgment and filtered notifications over a real SSE response", context do
    {:ok, handle} =
      Client.listen_subscriptions(
        context.client,
        %SubscriptionFilter{tools_list_changed: true}
      )

    assert_receive {:subscription_authorized, 1, :http_principal}, 1_000
    assert {:ok, acknowledgment} = SubscriptionHandle.next(handle, 1_000)
    assert acknowledgment["method"] == Methods.subscriptions_acknowledged()

    assert :ok =
             SubscriptionPublisher.publish(
               context.registry,
               :http_test,
               Methods.tools_list_changed(),
               %{}
             )

    assert {:ok, event} = SubscriptionHandle.next(handle, 1_000)
    assert event["method"] == Methods.tools_list_changed()
    assert event["params"]["_meta"][@subscription_id_key] == 1
  end

  test "keepalive comments are ignored by the client", context do
    {:ok, handle} =
      Client.listen_subscriptions(
        context.client,
        %SubscriptionFilter{tools_list_changed: true}
      )

    assert {:ok, _acknowledgment} = SubscriptionHandle.next(handle, 1_000)
    assert SubscriptionHandle.next(handle, 35) == {:error, :timeout}

    assert :ok =
             SubscriptionPublisher.publish(
               context.registry,
               :http_test,
               Methods.tools_list_changed(),
               %{}
             )

    assert {:ok, event} = SubscriptionHandle.next(handle, 1_000)
    assert event["method"] == Methods.tools_list_changed()
  end

  test "server graceful completion reaches the client and closes the stream", context do
    {:ok, handle} =
      Client.listen_subscriptions(
        context.client,
        %SubscriptionFilter{tools_list_changed: true}
      )

    assert {:ok, _acknowledgment} = SubscriptionHandle.next(handle, 1_000)
    [{worker, _value}] = Registry.lookup(context.registry, {:mcp_subscriptions, :http_test})

    assert :ok = SubscriptionWorker.complete(worker)
    assert {:ok, %ListenResult{} = result} = SubscriptionHandle.next(handle, 1_000)
    assert result.meta[@subscription_id_key] == 1
    assert SubscriptionHandle.next(handle, 0) == {:error, :closed}
  end

  test "closing the handle cancels only its HTTP response stream", context do
    filter = %SubscriptionFilter{tools_list_changed: true}
    {:ok, first} = Client.listen_subscriptions(context.client, filter)
    {:ok, second} = Client.listen_subscriptions(context.client, filter)

    assert {:ok, _acknowledgment} = SubscriptionHandle.next(first, 1_000)
    assert {:ok, _acknowledgment} = SubscriptionHandle.next(second, 1_000)

    workers = Registry.lookup(context.registry, {:mcp_subscriptions, :http_test})
    {first_worker, _value} = Enum.find(workers, fn {worker, _value} -> worker_id(worker) == 1 end)
    ref = Process.monitor(first_worker)

    assert :ok = SubscriptionHandle.close(first)
    assert_receive {:DOWN, ^ref, :process, ^first_worker, :normal}, 1_000

    assert :ok =
             SubscriptionPublisher.publish(
               context.registry,
               :http_test,
               Methods.tools_list_changed(),
               %{}
             )

    assert {:ok, event} = SubscriptionHandle.next(second, 1_000)
    assert event["params"]["_meta"][@subscription_id_key] == 2
  end

  test "an HTTP event flood is cut off at the client queue limit", context do
    {:ok, handle} =
      Client.listen_subscriptions(
        context.client,
        %SubscriptionFilter{tools_list_changed: true},
        queue_limit: 2
      )

    assert {:ok, _acknowledgment} = SubscriptionHandle.next(handle, 1_000)

    for sequence <- 1..100 do
      assert :ok =
               SubscriptionPublisher.publish(
                 context.registry,
                 :http_test,
                 Methods.tools_list_changed(),
                 %{"sequence" => sequence}
               )
    end

    # The HTTP stream applies backpressure across several supervised processes.
    # Wait until the client worker has observed the terminal overflow before
    # consuming the queue so the assertion is independent of scheduler speed.
    worker = Map.fetch!(handle, :worker)
    assert :ok = await_terminal_subscription(worker, 2_000)

    outcomes =
      Enum.reduce_while(1..3, [], fn _attempt, acc ->
        case SubscriptionHandle.next(handle, 1_000) do
          {:error, :queue_overflow} = error -> {:halt, [error | acc]}
          {:ok, event} -> {:cont, [{:ok, event} | acc]}
        end
      end)

    assert {:error, :queue_overflow} in outcomes
    assert Enum.count(outcomes, &match?({:ok, _event}, &1)) <= 2
    _ = :sys.get_state(context.client)
    transport = Client.transport(context.client)
    assert :sys.get_state(transport).subscriptions == %{}
  end

  defp await_terminal_subscription(worker, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_terminal_subscription_until(worker, deadline)
  end

  defp await_terminal_subscription_until(worker, deadline) do
    if :sys.get_state(worker).terminal? do
      :ok
    else
      wait_for_terminal_subscription(worker, deadline)
    end
  end

  defp wait_for_terminal_subscription(worker, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      receive do
      after
        1 -> await_terminal_subscription_until(worker, deadline)
      end
    end
  end

  test "subscription response disables proxy buffering", context do
    request = listen_request(99)

    assert {:ok, response} =
             Req.post(context.url,
               body: Jason.encode!(request),
               headers: listen_headers(),
               into: :self,
               receive_timeout: :infinity
             )

    assert response.status == 200
    assert Req.Response.get_header(response, "x-accel-buffering") == ["no"]

    assert Req.Response.get_header(response, "content-type") == [
             "text/event-stream; charset=utf-8"
           ]

    assert :ok = Req.cancel_async_response(response)
  end

  test "Last-Event-ID resumption is rejected", context do
    headers = [{"last-event-id", "old-event"} | listen_headers()]

    assert {:ok, response} =
             Req.post(context.url, body: Jason.encode!(listen_request(77)), headers: headers)

    assert response.status == 400
    assert response.body["error"]["data"] =~ "resumption is unsupported"
    assert Registry.lookup(context.registry, {:mcp_subscriptions, :http_test}) == []
  end

  test "legacy subscription request without a negotiated session is rejected before authorization",
       context do
    request =
      78
      |> listen_request()
      |> put_in(
        ["params", "_meta", "io.modelcontextprotocol/protocolVersion"],
        "2025-11-25"
      )

    headers =
      Enum.map(listen_headers(), fn
        {"mcp-protocol-version", _version} -> {"mcp-protocol-version", "2025-11-25"}
        header -> header
      end)

    assert {:ok, response} =
             Req.post(context.url, body: Jason.encode!(request), headers: headers)

    assert response.status == 404
    assert response.body["error"]["message"] == "Session not found"
    refute_receive {:subscription_authorized, 78, _identity}
    assert Registry.lookup(context.registry, {:mcp_subscriptions, :http_test}) == []
  end

  defp worker_id(worker), do: :sys.get_state(worker).id

  defp listen_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => Methods.subscriptions_listen(),
      "params" => %{
        "notifications" => %{"toolsListChanged" => true},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
  end

  defp listen_headers do
    [
      {"content-type", "application/json"},
      {"accept", "text/event-stream"},
      {"mcp-protocol-version", @version},
      {"mcp-method", Methods.subscriptions_listen()}
    ]
  end
end
