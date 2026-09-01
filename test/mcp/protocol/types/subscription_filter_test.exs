defmodule MCP.Protocol.Types.SubscriptionFilterTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Types.SubscriptionFilter

  describe "from_map/1" do
    test "decodes every final-schema field and preserves URI order and duplicates" do
      filter =
        SubscriptionFilter.from_map(%{
          "toolsListChanged" => true,
          "promptsListChanged" => true,
          "resourcesListChanged" => true,
          "resourceSubscriptions" => ["file:///a", "file:///a", "file:///b"]
        })

      assert filter.tools_list_changed
      assert filter.prompts_list_changed
      assert filter.resources_list_changed
      assert filter.resource_subscriptions == ["file:///a", "file:///a", "file:///b"]
    end

    test "defaults every opt-in to disabled" do
      assert SubscriptionFilter.from_map(%{}) == %SubscriptionFilter{}
    end

    test "rejects unknown and incorrectly typed fields" do
      assert_raise ArgumentError, fn ->
        SubscriptionFilter.from_map(%{"toolsListChanged" => true, "other" => true})
      end

      assert_raise ArgumentError, fn ->
        SubscriptionFilter.from_map(%{"promptsListChanged" => "yes"})
      end

      assert_raise ArgumentError, fn ->
        SubscriptionFilter.from_map(%{"resourceSubscriptions" => ["file:///a", 7]})
      end
    end

    test "bounds untrusted resource subscription cardinality" do
      resources = for id <- 1..16_385, do: "file:///resource/#{id}"

      assert_raise ArgumentError, ~r/resourceSubscriptions exceeds 16384 entries/, fn ->
        SubscriptionFilter.from_map(%{"resourceSubscriptions" => resources})
      end
    end

    test "bounds untrusted resource subscription byte size" do
      resources = [String.duplicate("x", 262_145)]

      assert_raise ArgumentError, ~r/resourceSubscriptions exceeds 262144 bytes/, fn ->
        SubscriptionFilter.from_map(%{"resourceSubscriptions" => resources})
      end
    end
  end

  describe "to_map/1" do
    test "emits only enabled notification families" do
      filter = %SubscriptionFilter{
        tools_list_changed: true,
        resource_subscriptions: ["file:///guide.md"]
      }

      assert SubscriptionFilter.to_map(filter) == %{
               "toolsListChanged" => true,
               "resourceSubscriptions" => ["file:///guide.md"]
             }

      assert Jason.decode!(Jason.encode!(filter)) == SubscriptionFilter.to_map(filter)
    end
  end
end
