defmodule MCP.Transport.Stdio.SignalTest do
  use ExUnit.Case, async: true

  alias MCP.Test.StdioFixture

  test "a process-exit race does not leak kill diagnostics to the SDK's stderr" do
    app_ebin = Application.app_dir(:mcp_elixir_sdk, "ebin")

    expression =
      ~S|MCP.Transport.Stdio.Signal.dispatch(99_999_999, :sigterm, 1_000)|

    {command, args} =
      StdioFixture.elixir(["-pa", app_ebin, "-e", expression])

    assert {"", 0} = System.cmd(command, args, stderr_to_stdout: true)
  end
end
