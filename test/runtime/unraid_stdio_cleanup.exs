fixture =
  case System.argv() do
    [path] -> Path.expand(path)
    ["--", path] -> Path.expand(path)
    _ -> raise "usage: mix run test/runtime/unraid_stdio_cleanup.exs -- FIXTURE_PATH"
  end

if System.get_env("MCP_ERLEXEC_ALLOW_ROOT") == "1" do
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

child_pid =
  receive do
    {:mcp_message, %{"result" => %{"pid" => pid}}} -> pid
  after
    5_000 -> raise "stdio fixture did not report its descendant PID"
  end

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

alive? = fn pid ->
  case File.read("/proc/#{pid}/stat") do
    {:ok, stat} ->
      case String.split(stat, " ", parts: 4) do
        [_pid, _name, "Z", _rest] -> false
        _running -> true
      end

    {:error, _reason} ->
      false
  end
end

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
  :ok ->
    IO.puts(
      "unraid stdio cleanup passed root_pid=#{root_pid} root_pgid=#{root_pgid} " <>
        "descendant_pid=#{child_pid} descendant_pgid=#{child_pgid}"
    )

  {:error, reason} ->
    raise "#{reason} root_pid=#{root_pid} root_pgid=#{root_pgid} " <>
            "descendant_pid=#{child_pid} descendant_pgid=#{child_pgid}"
end
