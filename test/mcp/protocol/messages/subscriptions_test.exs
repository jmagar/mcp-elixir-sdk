defmodule MCP.Protocol.Messages.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Messages.Subscriptions.AcknowledgedParams
  alias MCP.Protocol.Messages.Subscriptions.ListenParams
  alias MCP.Protocol.Messages.Subscriptions.ListenResult
  alias MCP.Protocol.Types.SubscriptionFilter

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  test "listen params round-trip the notification filter and request metadata" do
    map = %{
      "notifications" => %{
        "toolsListChanged" => true,
        "resourceSubscriptions" => ["file:///guide.md"]
      },
      "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
    }

    params = ListenParams.from_map(map)

    assert %SubscriptionFilter{tools_list_changed: true} = params.notifications
    assert ListenParams.to_map(params) == map
    assert Jason.decode!(Jason.encode!(params)) == map
  end

  test "listen params require a notification filter" do
    assert_raise KeyError, fn -> ListenParams.from_map(%{"_meta" => %{}}) end
  end

  test "acknowledgment params round-trip the honored filter and correlation metadata" do
    map = %{
      "notifications" => %{"resourcesListChanged" => true},
      "_meta" => %{@subscription_id_key => 42}
    }

    params = AcknowledgedParams.from_map(map)

    assert params.notifications.resources_list_changed
    assert AcknowledgedParams.to_map(params) == map
    assert Jason.decode!(Jason.encode!(params)) == map
  end

  test "graceful listen result uses the final result envelope body" do
    map = %{
      "resultType" => "complete",
      "_meta" => %{@subscription_id_key => "subscription-7"}
    }

    result = ListenResult.from_map(map)

    assert result.result_type == "complete"
    assert ListenResult.to_map(result) == map
    assert Jason.decode!(Jason.encode!(result)) == map
  end

  test "graceful listen result requires the complete result type" do
    meta = %{"_meta" => %{@subscription_id_key => "subscription-7"}}

    assert_raise KeyError, fn -> ListenResult.from_map(meta) end

    assert_raise ArgumentError, ~r/resultType must be complete/, fn ->
      ListenResult.from_map(Map.put(meta, "resultType", "input_required"))
    end

    assert_raise ArgumentError, ~r/resultType must be complete/, fn ->
      ListenResult.to_map(%ListenResult{meta: meta["_meta"], result_type: "other"})
    end
  end

  test "acknowledgment and result require a string or integer subscription ID" do
    for module <- [AcknowledgedParams, ListenResult] do
      assert_raise ArgumentError, fn ->
        module.from_map(%{
          "notifications" => %{},
          "resultType" => "complete",
          "_meta" => %{}
        })
      end

      assert_raise ArgumentError, fn ->
        module.from_map(%{
          "notifications" => %{},
          "resultType" => "complete",
          "_meta" => %{@subscription_id_key => nil}
        })
      end
    end
  end

  test "acknowledgment and result reject floating-point subscription IDs" do
    for module <- [AcknowledgedParams, ListenResult] do
      assert_raise ArgumentError, fn ->
        module.from_map(%{
          "notifications" => %{},
          "resultType" => "complete",
          "_meta" => %{@subscription_id_key => 1.5}
        })
      end
    end
  end
end
