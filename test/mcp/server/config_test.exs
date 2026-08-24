defmodule MCP.Server.ConfigTest do
  use ExUnit.Case, async: true

  alias MCP.Server.Config
  alias MCP.Test.{EchoHandler, StatelessHandler}

  defmodule RaisingHandler do
    def init(_opts), do: raise("boom")
  end

  defmodule ThrowingHandler do
    def init(_opts), do: throw(:boom)
  end

  defmodule ExitingHandler do
    def init(_opts), do: exit(:boom)
  end

  defmodule InvalidHandler do
    def init(_opts), do: :not_a_tuple
  end

  defmodule ErrorHandler do
    def init(_opts), do: {:error, :application_error}
  end

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

  test "normalizes all handler init failures" do
    assert {:error, {:handler_init_failed, {:raised, %RuntimeError{message: "boom"}}}} =
             Config.build(RaisingHandler, [])

    assert Config.build(ThrowingHandler, []) ==
             {:error, {:handler_init_failed, {:thrown, :boom}}}

    assert Config.build(ExitingHandler, []) ==
             {:error, {:handler_init_failed, {:exited, :boom}}}

    assert Config.build(InvalidHandler, []) ==
             {:error, {:handler_init_failed, {:invalid_return, :not_a_tuple}}}
  end

  test "normalizes errors returned normally by handler init" do
    assert Config.build(ErrorHandler, []) ==
             {:error, {:handler_init_failed, :application_error}}
  end
end
