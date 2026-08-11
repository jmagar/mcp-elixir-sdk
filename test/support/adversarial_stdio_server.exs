mode = List.first(System.argv())

case mode do
  "oversized" ->
    :ok = :file.write(:standard_io, String.duplicate("x", 65))
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
    IO.binwrite(
      Enum.map_join(1..5, "", fn id ->
        ~s({"jsonrpc":"2.0","id":#{id},"result":{"ok":true}}\n)
      end)
    )

    Process.sleep(:infinity)

  "frame_burst_exit" ->
    # Writes a burst and exits immediately, so the close notification races the
    # frames still buffered behind a frame-turn boundary.
    IO.binwrite(
      Enum.map_join(1..5, "", fn id ->
        ~s({"jsonrpc":"2.0","id":#{id},"result":{"ok":true}}\n)
      end)
    )

  "frame_flood" ->
    IO.binwrite(
      Enum.map_join(1..1_000, "", fn id ->
        ~s({"jsonrpc":"2.0","id":#{id},"result":{"ok":true}}\n)
      end)
    )

    Process.sleep(:infinity)

  "truncated_exit" ->
    IO.binwrite(~s({"jsonrpc":"2.0","id":1,"result":{"ok":true}}))

  "chunked_stderr" ->
    for chunk <- ["abc", "def", "ghi"] do
      IO.binwrite(:stderr, chunk)
      Process.sleep(25)
    end

    IO.puts(~s({"jsonrpc":"2.0","id":1,"result":{"ok":true}}))
    Process.sleep(:infinity)

  other ->
    # Without this clause an unknown or missing mode exits with a CaseClauseError
    # and the parent only observes a closed stdout, so the calling test fails
    # with an unrelated timeout instead of naming the cause.
    IO.puts(:stderr, "adversarial_stdio_server: unknown mode #{inspect(other)}")
    System.halt(2)
end
