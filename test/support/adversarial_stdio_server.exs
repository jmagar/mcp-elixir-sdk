mode = List.first(System.argv())

case mode do
  "oversized" ->
    IO.binwrite(String.duplicate("x", 65))
    Process.sleep(:infinity)

  "malformed" ->
    IO.binwrite("not-json\n")
    Process.sleep(:infinity)

  "scalar" ->
    IO.binwrite("42\n")
    Process.sleep(:infinity)

  "stderr_then_valid" ->
    IO.binwrite(:stderr, String.duplicate("s", 64))
    IO.puts(~s({"jsonrpc":"2.0","id":1,"result":{"ok":true}}))
    Process.sleep(:infinity)

  "descendant" ->
    port = Port.open({:spawn_executable, ~c"/bin/sleep"}, [{:args, ["60"]}])
    {:os_pid, child_pid} = Port.info(port, :os_pid)
    IO.puts(~s({"jsonrpc":"2.0","id":1,"result":{"pid":#{child_pid}}}))
    Process.sleep(:infinity)

  "malformed_descendant" ->
    port = Port.open({:spawn_executable, ~c"/bin/sleep"}, [{:args, ["60"]}])
    {:os_pid, child_pid} = Port.info(port, :os_pid)
    IO.puts(~s({"jsonrpc":"2.0","id":1,"result":{"parent":#{System.pid()},"child":#{child_pid}}}))
    IO.binwrite("not-json\n")
    Process.sleep(:infinity)

  "frame_burst" ->
    for id <- 1..5 do
      IO.puts(~s({"jsonrpc":"2.0","id":#{id},"result":{"ok":true}}))
    end

    Process.sleep(:infinity)

  "chunked_stderr" ->
    for chunk <- ["abc", "def", "ghi"] do
      IO.binwrite(:stderr, chunk)
      Process.sleep(25)
    end

    IO.puts(~s({"jsonrpc":"2.0","id":1,"result":{"ok":true}}))
    Process.sleep(:infinity)
end
