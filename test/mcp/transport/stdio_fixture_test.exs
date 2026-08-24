defmodule MCP.Test.StdioFixtureTest do
  use ExUnit.Case, async: true

  alias MCP.Test.StdioFixture

  test "the shared Elixir launcher bounds scheduler and async thread counts" do
    {command, args} =
      StdioFixture.elixir([
        "-e",
        ~S|IO.write("#{:erlang.system_info(:schedulers)}:#{:erlang.system_info(:thread_pool_size)}")|
      ])

    assert {"2:2", 0} = System.cmd(command, args)
  end
end
