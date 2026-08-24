defmodule MCP.Transport.Stdio.SignalTest do
  use ExUnit.Case, async: true

  alias MCP.Test.StdioFixture
  alias MCP.Transport.Stdio.Signal

  test "a failed signal reports its exit status and bounded diagnostic" do
    assert {:error, {:signal_failed, :sigterm, 99_999_999, status, diagnostic}} =
             Signal.dispatch(99_999_999, :sigterm, 1_000)

    assert status > 0
    assert byte_size(diagnostic) <= 4_096
    assert diagnostic != ""
  end

  test "a process-exit race does not leak kill diagnostics to the SDK's stderr" do
    app_ebin = Application.app_dir(:mcp_elixir_sdk, "ebin")

    expression =
      ~S|MCP.Transport.Stdio.Signal.dispatch(99_999_999, :sigterm, 1_000)|

    {command, args} =
      StdioFixture.elixir(["-pa", app_ebin, "-e", expression])

    assert {"", 0} = System.cmd(command, args, stderr_to_stdout: true)
  end
end
