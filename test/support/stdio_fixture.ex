defmodule MCP.Test.StdioFixture do
  @moduledoc false

  @erl_switches "+S 2:2 +A 2"

  def elixir(args) when is_list(args) do
    {System.find_executable("elixir"), ["--erl", @erl_switches | args]}
  end
end
