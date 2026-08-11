# Microsandbox stdio round trip.
#
# Run with:
#
#     mix run --no-start test/runtime/microsandbox_stdio_roundtrip.exs
#
# Proves three things the unit suite cannot, because they need a real third-party
# MCP server and a real containment boundary:
#
#   1. An MCP stdio upstream runs unmodified inside a microsandbox microVM when
#      launched through `msb exec --stream`. The transport needs no change: a
#      sandbox is a different `:command`/`:args`, nothing more.
#   2. Normal close reaps the host launcher AND the in-guest server process.
#   3. An abnormal BEAM death (SIGKILL, where `terminate/2` never runs) also
#      leaves no orphan. This is the case `unraid_stdio_cleanup.exs` does not
#      cover: there, cleanup runs on the close path.
#
# The microVM itself is deliberately NOT reclaimed by any of this — `msb create`
# is persistent by design. A gateway must stop it explicitly and rely on
# `--idle-timeout` as the backstop for case 3. The probe asserts that the VM
# survives, so the requirement stays visible rather than being assumed away.
#
# Requires `msb` on PATH (or `MCP_MSB_BIN`), a KVM-capable host, and network
# access on the first run to install the reference server into the sandbox.

defmodule MicrosandboxProbe do
  @moduledoc false

  @sandbox System.get_env("MCP_MSB_SANDBOX", "mcp-everything")
  @image System.get_env("MCP_MSB_IMAGE", "mirror.gcr.io/library/node:22-alpine")
  @server "mcp-server-everything"
  # Host teardown after SIGKILL is not instantaneous: exec-port observes the
  # broken pipe rather than being signalled, so allow a generous budget. An
  # observed run reaped between 5s and 30s.
  @orphan_timeout_ms 60_000

  def msb_bin do
    System.get_env("MCP_MSB_BIN") || System.find_executable("msb") ||
      raise "msb not found; install it (mise use -g microsandbox@latest) or set MCP_MSB_BIN"
  end

  def launch_args,
    do: ["exec", "--stream", "--quiet", @sandbox, "--", @server, "stdio"]

  def child_env,
    do: [{"HOME", System.fetch_env!("HOME")}, {"PATH", System.fetch_env!("PATH")}]

  @doc "Creates the sandbox and installs the reference server if not already present."
  def ensure_sandbox! do
    unless sandbox_exists?() do
      IO.puts("creating sandbox #{@sandbox} from #{@image}")
      msb!(["create", @image, "--name", @sandbox, "-m", "1G", "-c", "2", "--replace"])
    end

    # `msb start` errors on an already-running sandbox, and the probe is meant
    # to be re-runnable against a warm one.
    unless sandbox_running?(), do: msb!(["start", @sandbox])

    case msb(["exec", @sandbox, "--", "sh", "-c", "command -v #{@server}"]) do
      {_output, 0} ->
        :ok

      _missing ->
        IO.puts("installing @modelcontextprotocol/server-everything into #{@sandbox}")

        msb!([
          "exec",
          @sandbox,
          "--",
          "npm",
          "install",
          "-g",
          "@modelcontextprotocol/server-everything"
        ])
    end
  end

  def sandbox_running? do
    {output, _status} = msb(["list", "--running"])
    String.contains?(output, @sandbox)
  end

  defp sandbox_exists? do
    {output, _status} = msb(["list"])
    String.contains?(output, @sandbox)
  end

  @doc "Whether any process inside the guest is still running the MCP server."
  def guest_server_running? do
    case msb(["exec", @sandbox, "--", "sh", "-c", "ps -o args | grep #{@server} | grep -v grep"]) do
      {output, 0} -> String.contains?(output, @server)
      _none -> false
    end
  end

  @doc "Parent pid of an OS process, or nil once it is gone."
  def parent_pid(os_pid) do
    with {:ok, stat} <- File.read("/proc/#{os_pid}/stat"),
         # Field 4 is ppid, but the comm field (2) may itself contain spaces and
         # parentheses, so split after the final ')' rather than on whitespace.
         [_comm, rest] <- String.split(stat, ") ", parts: 2),
         [_state, ppid | _] <- String.split(rest, " ") do
      String.to_integer(ppid)
    else
      _ -> nil
    end
  end

  def await_reaped!(os_pids, label) do
    deadline = System.monotonic_time(:millisecond) + @orphan_timeout_ms
    do_await_reaped!(os_pids, label, deadline)
  end

  defp do_await_reaped!(os_pids, label, deadline) do
    alive = Enum.filter(os_pids, &alive?/1)

    cond do
      alive == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "#{label}: orphaned host processes still alive after " <>
                "#{@orphan_timeout_ms}ms: #{inspect(alive)}"

      true ->
        Process.sleep(200)
        do_await_reaped!(os_pids, label, deadline)
    end
  end

  # A zombie has been killed but not yet reaped by its parent; it holds no
  # resources and is not an orphan for our purposes.
  def alive?(os_pid) do
    MCP.Transport.Stdio.Process.os_process_alive?(os_pid) and not zombie?(os_pid)
  end

  defp zombie?(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} ->
        case String.split(stat, ") ", parts: 2) do
          [_comm, rest] -> String.starts_with?(rest, "Z")
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc """
  Environment for the re-executed child BEAM.

  The child resolves its own sandbox and `msb` location, so every variable that
  configures this probe has to cross the process boundary explicitly — the port
  is spawned with a closed environment, not an inherited one.
  """
  def child_beam_env(build_path) do
    configured =
      for name <- ~w(MCP_MSB_BIN MCP_MSB_SANDBOX MCP_MSB_IMAGE),
          value = System.get_env(name),
          do: {String.to_charlist(name), String.to_charlist(value)}

    [
      {~c"ERL_LIBS", String.to_charlist(Path.join(build_path, "lib"))},
      {~c"HOME", String.to_charlist(System.fetch_env!("HOME"))},
      {~c"PATH", String.to_charlist(System.fetch_env!("PATH"))},
      {~c"SHELL", String.to_charlist(System.get_env("SHELL", "/bin/sh"))}
    ] ++ configured
  end

  def msb!(args) do
    case msb(args) do
      {output, 0} -> output
      {output, status} -> raise "msb #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end

  # Buffered `msb exec` drains stdin to EOF before it runs anything, and an
  # Erlang port never closes the child's stdin — the pair deadlocks. (This is
  # the same hazard microsandbox documents for its own buffered path, which is
  # why the MCP launch below uses `--stream`.) Redirect from /dev/null, passing
  # the command through "$0"/"$@" so no argument is ever re-parsed by the shell.
  def msb(args) do
    System.cmd("/bin/sh", ["-c", ~s(exec "$0" "$@" </dev/null), msb_bin() | args],
      stderr_to_stdout: true
    )
  end
end

# ---------------------------------------------------------------------------
# Child mode: connect, report the OS pids the parent must watch, then block.
# Re-executed by the parent as a separate BEAM so it can be SIGKILLed.
# ---------------------------------------------------------------------------

run_child = fn ->
  {:ok, _started} = Application.ensure_all_started(:mcp_elixir_sdk)

  {:ok, transport} =
    MCP.Transport.Stdio.start_link(
      owner: self(),
      command: MicrosandboxProbe.msb_bin(),
      args: MicrosandboxProbe.launch_args(),
      env: MicrosandboxProbe.child_env(),
      security_policy: MCP.Transport.Stdio.SecurityPolicy.gateway()
    )

  launcher_pid = :sys.get_state(:sys.get_state(transport).process).os_pid
  exec_port_pid = MicrosandboxProbe.parent_pid(launcher_pid)

  IO.puts("READY beam=#{System.pid()} launcher=#{launcher_pid} exec_port=#{exec_port_pid}")
  Process.sleep(:infinity)
end

# ---------------------------------------------------------------------------
# Parent mode.
# ---------------------------------------------------------------------------

run_parent = fn ->
  {:ok, _started} = Application.ensure_all_started(:mcp_elixir_sdk)
  MicrosandboxProbe.ensure_sandbox!()

  # -- Phase 1: a real MCP server answers through the microVM boundary. -------

  {:ok, client} =
    MCP.Client.start_link(
      transport:
        {MCP.Transport.Stdio,
         command: MicrosandboxProbe.msb_bin(),
         args: MicrosandboxProbe.launch_args(),
         env: MicrosandboxProbe.child_env(),
         security_policy: MCP.Transport.Stdio.SecurityPolicy.gateway()},
      client_info: %{name: "microsandbox-probe", version: "0.1.0"},
      request_timeout: 60_000
    )

  {:ok, info} = MCP.Client.connect(client, 90_000)
  server = MCP.Client.server_info(client)

  # The reference server has no 2026-07-28 support, so reaching a usable session
  # at all means the negotiation ladder walked down to a revision both sides
  # hold. Assert it landed inside the declared support set rather than on an
  # exact revision, which the server is free to change.
  unless info.protocol_version in MCP.Protocol.Revision.supported() do
    raise "negotiated #{info.protocol_version}, outside the declared support set"
  end

  {:ok, %{"tools" => tools}} = MCP.Client.list_tools(client)
  if tools == [], do: raise("tools/list returned no tools")

  {:ok, result} = MCP.Client.call_tool(client, "get-sum", %{"a" => 17, "b" => 25})
  text = result |> Map.get("content", []) |> Enum.map(& &1["text"]) |> Enum.join()
  unless String.contains?(text, "42"), do: raise("get-sum(17,25) returned #{inspect(text)}")

  transport = MCP.Client.transport(client)
  launcher_pid = :sys.get_state(:sys.get_state(transport).process).os_pid
  exec_port_pid = MicrosandboxProbe.parent_pid(launcher_pid)

  IO.puts(
    "roundtrip passed server=#{server.name} v#{server.version} " <>
      "era=#{info.protocol_version} tools=#{length(tools)} sum=#{inspect(text)}"
  )

  # -- Phase 2: normal close reaps the host launcher and the guest server. ----

  :ok = MCP.Client.close(client)
  MicrosandboxProbe.await_reaped!([launcher_pid], "normal close")

  if MicrosandboxProbe.guest_server_running?() do
    raise "normal close left #{inspect(launcher_pid)}'s server running inside the guest"
  end

  # erlexec registers ONE exec-port per BEAM — `gen_server:start_link({local,
  # ?MODULE}, ...)` in deps/erlexec/src/exec.erl:544 — so every stdio upstream
  # multiplexes through the same port program. Closing one upstream must NOT
  # take it down; in a gateway that would be collateral damage to every sibling
  # upstream. Asserting it survives is the point, not an oversight.
  unless MicrosandboxProbe.alive?(exec_port_pid) do
    raise "closing one upstream killed the shared exec-port (#{exec_port_pid}); " <>
            "sibling upstreams would have died with it"
  end

  IO.puts(
    "normal close passed launcher=#{launcher_pid} reaped, " <>
      "shared exec_port=#{exec_port_pid} survived"
  )

  # -- Phase 3: SIGKILL, where terminate/2 never runs. -----------------------

  build = Mix.Project.build_path()

  port =
    Port.open({:spawn_executable, System.find_executable("elixir")}, [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      {:line, 4096},
      {:args, [__ENV__.file, "child"]},
      {:env, MicrosandboxProbe.child_beam_env(build)}
    ])

  await_ready = fn await_ready ->
    receive do
      {^port, {:data, {_flag, line}}} ->
        case Regex.run(~r/^READY beam=(\d+) launcher=(\d+) exec_port=(\d+)/, line) do
          [_, beam, launcher, exec_port] ->
            {String.to_integer(beam), String.to_integer(launcher), String.to_integer(exec_port)}

          nil ->
            IO.puts("child: #{line}")
            await_ready.(await_ready)
        end

      {^port, {:exit_status, status}} ->
        raise "child probe exited (#{status}) before reporting READY"
    after
      120_000 -> raise "child probe never reported READY"
    end
  end

  {child_beam, child_launcher, child_exec_port} = await_ready.(await_ready)

  # SIGKILL is the point: no OTP teardown, no terminate/2, no close path.
  {_output, 0} = System.cmd("/bin/kill", ["-9", "--", Integer.to_string(child_beam)])

  MicrosandboxProbe.await_reaped!([child_launcher, child_exec_port], "SIGKILL")

  if MicrosandboxProbe.guest_server_running?() do
    raise "SIGKILL left the server running inside the guest"
  end

  IO.puts(
    "sigkill cleanup passed beam=#{child_beam} launcher=#{child_launcher} " <>
      "exec_port=#{child_exec_port}"
  )

  # -- Phase 4: the microVM is the gateway's to reclaim, not the SDK's. -------

  unless MicrosandboxProbe.sandbox_running?() do
    raise "sandbox #{inspect(System.get_env("MCP_MSB_SANDBOX", "mcp-everything"))} " <>
            "stopped on its own; the probe can no longer show that VM reclamation " <>
            "is the consumer's responsibility"
  end

  IO.puts("microvm survived both teardowns; consumers must stop it explicitly")
end

case System.argv() do
  ["child"] -> run_child.()
  ["--", "child"] -> run_child.()
  [] -> run_parent.()
  other -> raise "usage: mix run --no-start #{__ENV__.file} (got #{inspect(other)})"
end
