defmodule MCP.Server.ConfigTest do
  use ExUnit.Case, async: true

  alias MCP.Server.Config
  alias MCP.Test.{EchoHandler, StatelessHandler}

  test "accepts only nonnegative cache TTLs and protocol cache scopes" do
    assert {:ok, %{cache_defaults: {0, "public"}}} = Config.build(EchoHandler, [])

    assert {:ok, %{cache_defaults: {1_000, "private"}}} =
             Config.build(EchoHandler, cache_defaults: {1_000, "private"})

    for invalid <- [{-1, "public"}, {0, "shared"}, {1.0, "private"}, :invalid] do
      assert Config.build(EchoHandler, cache_defaults: invalid) ==
               {:error, {:invalid_cache_defaults, invalid}}
    end
  end

  test "advertises list changes only when subscription delivery is enabled" do
    assert {:ok, %{capabilities: capabilities}} = Config.build(StatelessHandler, [])
    assert capabilities.tools.list_changed == nil
    assert capabilities.resources.list_changed == nil
    assert capabilities.prompts.list_changed == nil

    assert {:ok, %{capabilities: subscribed}} =
             Config.build(StatelessHandler, subscriptions_enabled: true)

    assert subscribed.tools.list_changed == true
    assert subscribed.resources.list_changed == true
    assert subscribed.prompts.list_changed == true
  end
end
