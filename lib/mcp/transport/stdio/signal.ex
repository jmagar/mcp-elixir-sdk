defmodule MCP.Transport.Stdio.Signal do
  @moduledoc false

  @max_diagnostic_bytes 4_096

  @type dispatch_error ::
          {:signal_failed, :sigterm | :sigkill, pos_integer(), non_neg_integer(), binary()}

  @spec dispatch(pos_integer(), :sigterm | :sigkill, pos_integer()) ::
          :ok | :timeout | {:error, dispatch_error()}
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

    await_exit(port, signal, pid, System.monotonic_time(:millisecond) + timeout_ms, "")
  end

  defp await_exit(port, signal, pid, deadline, diagnostic) do
    receive do
      {^port, {:data, data}} ->
        diagnostic =
          binary_part(
            diagnostic <> data,
            0,
            min(byte_size(diagnostic <> data), @max_diagnostic_bytes)
          )

        await_exit(port, signal, pid, deadline, diagnostic)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        {:error, {:signal_failed, signal, pid, status, String.trim(diagnostic)}}
    after
      max(deadline - System.monotonic_time(:millisecond), 1) ->
        Port.close(port)
        :timeout
    end
  end
end
