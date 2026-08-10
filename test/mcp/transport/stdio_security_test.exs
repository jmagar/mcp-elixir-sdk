defmodule MCP.Transport.StdioSecurityTest do
  use ExUnit.Case, async: true

  alias MCP.Transport.Stdio
  alias MCP.Transport.Stdio.SecurityPolicy

  @fixture Path.expand("../../support/adversarial_stdio_server.exs", __DIR__)

  test "gateway defaults bound frames, close malformed output, and isolate diagnostics" do
    policy = SecurityPolicy.gateway()

    assert policy.max_frame_bytes == 1_000_000
    assert policy.max_frames_per_turn == 100
    assert policy.malformed_output == :close
    assert policy.stderr == :disable
    assert policy.environment == :replace
    assert policy.shutdown_timeout == 5_000
  end

  test "policy rejects invalid values" do
    assert {:error, {:invalid_security_policy, {:max_frame_bytes, 0}}} =
             SecurityPolicy.new(max_frame_bytes: 0)

    assert {:error, {:invalid_security_policy, {:stderr, :stdout}}} =
             SecurityPolicy.new(stderr: :stdout)

    assert {:error, {:invalid_security_policy, {:unknown_options, [:surprise]}}} =
             SecurityPolicy.new(surprise: true)
  end

  test "oversized incomplete stdout fails closed" do
    transport = start_transport("oversized", max_frame_bytes: 64, shutdown_timeout: 100)

    assert_receive {:mcp_transport_closed, {:protocol_violation, {:frame_too_large, 64}}},
                   5_000

    refute eventually(fn -> Process.alive?(transport) end, 3_000)
  end

  test "malformed and valid non-object JSON fail closed" do
    for {mode, expected} <- [
          {"malformed", :malformed_json},
          {"scalar", :non_protocol_json}
        ] do
      _transport = start_transport(mode, max_frame_bytes: 64)

      assert_receive {:mcp_transport_closed, {:protocol_violation, {^expected, _detail}}},
                     5_000
    end
  end

  test "captured stderr is bounded and never parsed as protocol stdout" do
    _transport =
      start_transport("stderr_then_valid", stderr: :capture, max_stderr_bytes: 8)

    assert_receive {:mcp_transport_stderr, stderr}, 5_000
    assert byte_size(stderr) == 8
    assert_receive {:mcp_message, %{"id" => 1, "result" => %{"ok" => true}}}, 5_000
    refute_receive {:mcp_message, "ssssssss"}
  end

  test "close terminates a spawned descendant in the process group" do
    transport = start_transport("descendant")
    assert_receive {:mcp_message, %{"result" => %{"pid" => child_pid}}}, 5_000
    assert os_process_alive?(child_pid)

    assert :ok = Stdio.close(transport)
    refute eventually(fn -> os_process_alive?(child_pid) end, 2_000)
  end

  defp start_transport(mode, policy_opts \\ []) do
    child_spec =
      Supervisor.child_spec(
        {MCP.Transport.Stdio,
         owner: self(),
         command: System.find_executable("elixir"),
         args: [@fixture, mode],
         security_policy: policy_opts},
        id: {MCP.Transport.Stdio, make_ref()}
      )

    start_supervised!(child_spec)
  end

  defp os_process_alive?(pid) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp eventually(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    eventually_until(fun, deadline)
  end

  defp eventually_until(fun, deadline) do
    if fun.() do
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        eventually_until(fun, deadline)
      else
        true
      end
    else
      false
    end
  end
end
