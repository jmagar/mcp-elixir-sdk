defmodule MCP.Transport.StdioSecurityTest do
  use ExUnit.Case, async: false

  alias MCP.Transport.Stdio
  alias MCP.Transport.Stdio.Process, as: StdioProcess
  alias MCP.Transport.Stdio.SecurityPolicy

  # Only the tests that spawn a subprocess or inspect the process tree are
  # platform-bound. Skipping the whole module would silently drop the
  # SecurityPolicy and framing coverage on non-Linux runners.
  @linux_only if :os.type() == {:unix, :linux},
                do: [],
                else: [skip: "Linux-only process-tree test"]

  @fixture Path.expand("../../support/adversarial_stdio_server.exs", __DIR__)
  @late_fixture Path.expand("../../support/late_descendant_stdio.sh", __DIR__)

  test "gateway defaults bound frames, close malformed output, and isolate diagnostics" do
    policy = SecurityPolicy.gateway()

    assert policy.max_frame_bytes == 1_000_000
    assert policy.max_frames_per_turn == 100
    assert policy.malformed_output == :close
    assert policy.stderr == :disable
    assert policy.environment == :replace
    assert policy.shutdown_timeout == 5_000
  end

  test "default policy inherits while gateway policy replaces the parent environment" do
    assert SecurityPolicy.default().environment == :inherit
    assert SecurityPolicy.gateway().environment == :replace
    assert %{SecurityPolicy.default() | environment: :replace} == SecurityPolicy.gateway()
  end

  test "client rejects malformed security policy structs" do
    policy = %SecurityPolicy{max_frames_per_turn: 0}
    Process.flag(:trap_exit, true)

    assert {:error, {:invalid_security_policy, {:max_frames_per_turn, 0}}} =
             Stdio.start_link(
               owner: self(),
               command: System.find_executable("true"),
               security_policy: policy
             )
  end

  test "policy rejects invalid values" do
    assert {:error, {:invalid_security_policy, {:max_frame_bytes, 0}}} =
             SecurityPolicy.new(max_frame_bytes: 0)

    assert {:error, {:invalid_security_policy, {:stderr, :stdout}}} =
             SecurityPolicy.new(stderr: :stdout)

    assert {:error, {:invalid_security_policy, {:unknown_options, [:surprise]}}} =
             SecurityPolicy.new(surprise: true)
  end

  @tag @linux_only
  test "oversized incomplete stdout fails closed" do
    transport = start_transport("oversized", max_frame_bytes: 64, shutdown_timeout: 100)

    assert_receive {:mcp_transport_closed, {:protocol_violation, {:frame_too_large, 64}}},
                   5_000

    refute stays_true?(fn -> Process.alive?(transport) end, 3_000)
  end

  @tag @linux_only
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

  @tag @linux_only
  test "captured stderr is bounded and never parsed as protocol stdout" do
    _transport =
      start_transport("stderr_then_valid", stderr: :capture, max_stderr_bytes: 8)

    assert_receive {:mcp_transport_stderr, stderr}, 5_000
    assert byte_size(stderr) == 8
    assert_receive {:mcp_message, %{"id" => 1, "result" => %{"ok" => true}}}, 5_000
    refute_receive {:mcp_message, "ssssssss"}
  end

  @tag @linux_only
  test "close terminates a spawned descendant in the process group" do
    transport = start_transport("descendant")
    assert_receive {:mcp_message, %{"result" => %{"pid" => child_pid}}}, 5_000
    assert os_process_alive?(child_pid)

    assert :ok = Stdio.close(transport)
    refute stays_true?(fn -> os_process_alive?(child_pid) end, 2_000)
  end

  @tag @linux_only
  test "protocol violation terminates the hostile parent and descendant" do
    _transport = start_transport("malformed_descendant", shutdown_timeout: 5_000)
    assert_receive {:mcp_message, %{"result" => %{"parent" => parent, "child" => child}}}, 5_000
    assert_receive {:mcp_transport_closed, {:protocol_violation, {:malformed_json, _}}}, 5_000
    refute stays_true?(fn -> os_process_alive?(parent) or os_process_alive?(child) end, 7_000)
  end

  @tag @linux_only
  test "close kills a descendant spawned during termination" do
    pid_file =
      Path.join(System.tmp_dir!(), "mcp-late-descendant-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(pid_file) end)

    transport =
      start_command_transport("/bin/sh", [@late_fixture, pid_file], shutdown_timeout: 500)

    assert_receive {:mcp_message, %{"result" => %{"ready" => true}}}, 5_000
    assert :ok = Stdio.close(transport)
    assert {:ok, pid_text} = File.read(pid_file)
    child_pid = pid_text |> String.trim() |> String.to_integer()
    refute stays_true?(fn -> os_process_alive?(child_pid) end, 3_000)
  end

  @tag @linux_only
  test "frame turns yield without loss or reordering" do
    _transport = start_transport("frame_burst", max_frames_per_turn: 2)

    # Every frame must survive the turn boundary in order. Asserting on the
    # transport's residual buffer instead would couple this to how the OS
    # bundles the fixture's single write into port messages.
    first_turn = for _ <- 1..2, do: receive_message()
    remaining = for _ <- 1..3, do: receive_message()
    assert Enum.map(first_turn ++ remaining, &get_in(&1, ["id"])) == [1, 2, 3, 4, 5]
  end

  @tag @linux_only
  test "frames buffered at a turn boundary survive a subprocess that exits immediately" do
    _transport = start_transport("frame_burst_exit", max_frames_per_turn: 2)

    ids = for _ <- 1..5, do: get_in(receive_message(), ["id"])
    assert ids == [1, 2, 3, 4, 5]
    assert_receive {:mcp_transport_closed, _reason}, 5_000
  end

  @tag @linux_only
  test "stderr capture limit applies across chunks" do
    _transport = start_transport("chunked_stderr", stderr: :capture, max_stderr_bytes: 7)

    {stderr, message} = collect_stderr_until_message("")
    assert stderr == "abcdefg"
    assert message["id"] == 1
    refute_receive {:mcp_transport_stderr, _}, 100
  end

  defp start_transport(mode, policy_opts \\ []) do
    start_command_transport(System.find_executable("elixir"), [@fixture, mode], policy_opts)
  end

  defp start_command_transport(command, args, policy_opts) do
    child_spec =
      Supervisor.child_spec(
        {MCP.Transport.Stdio,
         owner: self(), command: command, args: args, security_policy: policy_opts},
        id: {MCP.Transport.Stdio, make_ref()},
        restart: :temporary
      )

    start_supervised!(child_spec)
  end

  # Liveness is asserted through the same helper cleanup uses, so the test can
  # never disagree with the implementation about what "still running" means.
  defp os_process_alive?(pid), do: StdioProcess.os_process_alive?(pid)

  defp receive_message do
    receive do
      {:mcp_message, message} -> message
    after
      5_000 -> flunk("timed out waiting for stdio frame")
    end
  end

  defp stays_true?(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    stays_true_until?(fun, deadline)
  end

  defp stays_true_until?(fun, deadline) do
    if fun.() do
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        stays_true_until?(fun, deadline)
      else
        true
      end
    else
      false
    end
  end

  defp collect_stderr_until_message(acc) do
    receive do
      {:mcp_transport_stderr, chunk} -> collect_stderr_until_message(acc <> chunk)
      {:mcp_message, message} -> {acc, message}
    after
      5_000 -> flunk("timed out waiting for stdio output")
    end
  end
end
