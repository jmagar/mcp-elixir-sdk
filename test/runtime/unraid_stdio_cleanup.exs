# Run with:
#
#     mix run --no-start test/runtime/unraid_stdio_cleanup.exs -- FIXTURE_PATH
#
# `--no-start` matters when MCP_ERLEXEC_ALLOW_ROOT=1: `mix run` would otherwise
# start :erlexec from the application tree before this script body executes, and
# erlexec reads its root configuration at startup, so the gate below would have
# no effect. The script starts the application itself.

fixture =
  case System.argv() do
    [path] -> Path.expand(path)
    ["--", path] -> Path.expand(path)
    _ -> raise "usage: mix run --no-start test/runtime/unraid_stdio_cleanup.exs -- FIXTURE_PATH"
  end

if System.get_env("MCP_ERLEXEC_ALLOW_ROOT") == "1" do
  # Tolerate being run without --no-start: reconfiguring an already-started
  # erlexec requires stopping it first.
  _ = Application.stop(:erlexec)
  Application.put_env(:erlexec, :root, true)
  Application.put_env(:erlexec, :user, "root")
  Application.put_env(:erlexec, :limit_users, ["root"])
end

{:ok, _started} = Application.ensure_all_started(:mcp_elixir_sdk)

{:ok, transport} =
  MCP.Transport.Stdio.start_link(
    owner: self(),
    command: System.find_executable("elixir"),
    args: [fixture, "descendant"],
    env: [{"HOME", System.fetch_env!("HOME")}, {"PATH", System.fetch_env!("PATH")}],
    security_policy: MCP.Transport.Stdio.SecurityPolicy.gateway()
  )

await_descendant_pid = fn await_descendant_pid ->
  receive do
    {:mcp_message, %{"result" => %{"pid" => pid}}} ->
      pid

    other ->
      IO.puts("ignoring unexpected stdio message: #{inspect(other)}")
      await_descendant_pid.(await_descendant_pid)
  after
    5_000 -> raise "stdio fixture did not report its descendant PID"
  end
end

child_pid = await_descendant_pid.(await_descendant_pid)

stdio_state = :sys.get_state(transport)
process_state = :sys.get_state(stdio_state.process)

pgid = fn pid ->
  case System.cmd("/bin/ps", ["-o", "pgid=", "-p", Integer.to_string(pid)]) do
    {output, 0} -> String.trim(output)
    {_output, _status} -> "missing"
  end
end

root_pid = process_state.os_pid
root_pgid = pgid.(root_pid)
child_pgid = pgid.(child_pid)

evidence =
  "root_pid=#{root_pid} root_pgid=#{root_pgid} " <>
    "descendant_pid=#{child_pid} descendant_pgid=#{child_pgid}"

# Both groups must be resolvable for the printed evidence to mean anything.
#
# They are expected to DIFFER: the fixture's descendant creates its own process
# group, and the whole point of the probe is that cleanup still reaps it. If the
# two ever matched, the run would only prove that erlexec signalled the root
# command's own group — the weaker property this probe was written to rule out.
if root_pgid == "missing" or child_pgid == "missing" do
  raise "could not resolve process groups for the cleanup evidence #{evidence}"
end

if child_pgid == root_pgid do
  IO.puts(
    "warning: descendant shares the root process group, so this run does not " <>
      "exercise the escaped-group cleanup path #{evidence}"
  )
end

alive? = &MCP.Transport.Stdio.Process.os_process_alive?/1

true = alive?.(child_pid)
:ok = MCP.Transport.Stdio.close(transport)

deadline = System.monotonic_time(:millisecond) + 2_000

wait_until_stopped = fn wait_until_stopped ->
  cond do
    not alive?.(child_pid) ->
      :ok

    System.monotonic_time(:millisecond) >= deadline ->
      {:error, :descendant_still_alive}

    true ->
      Process.sleep(20)
      wait_until_stopped.(wait_until_stopped)
  end
end

case wait_until_stopped.(wait_until_stopped) do
  :ok -> IO.puts("unraid stdio cleanup passed #{evidence}")
  {:error, reason} -> raise "#{reason} #{evidence}"
end
