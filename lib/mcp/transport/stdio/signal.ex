defmodule MCP.Transport.Stdio.Signal do
  @moduledoc false

  @spec dispatch(pos_integer(), :sigterm | :sigkill, pos_integer()) :: :ok | :timeout
  def dispatch(pid, signal, timeout_ms)
      when is_integer(pid) and pid > 0 and signal in [:sigterm, :sigkill] and
             is_integer(timeout_ms) and timeout_ms > 0 do
    flag = if signal == :sigterm, do: "-TERM", else: "-KILL"

    port =
      Port.open(
        {:spawn_executable, ~c"/bin/kill"},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [flag, "--", Integer.to_string(pid)]
        ]
      )

    await_exit(port, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp await_exit(port, deadline) do
    receive do
      {^port, {:data, _expected_diagnostic}} -> await_exit(port, deadline)
      {^port, {:exit_status, _status}} -> :ok
    after
      max(deadline - System.monotonic_time(:millisecond), 1) ->
        Port.close(port)
        :timeout
    end
  end
end
