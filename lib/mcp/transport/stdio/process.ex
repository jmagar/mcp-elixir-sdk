defmodule MCP.Transport.Stdio.Process do
  @moduledoc false

  use GenServer

  defstruct [
    :owner,
    :exec_pid,
    :os_pid,
    :policy,
    :cleanup_marker,
    pending_stdout_bytes: 0,
    stdout_from: nil,
    stderr_bytes: 0,
    closed?: false
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec write(pid(), iodata()) :: :ok | {:error, term()}
  def write(process, data), do: GenServer.call(process, {:write, IO.iodata_to_binary(data)})

  @spec ack_stdout(pid(), non_neg_integer()) :: :ok
  def ack_stdout(process, bytes), do: GenServer.cast(process, {:ack_stdout, bytes})

  @spec close(pid(), timeout()) :: :ok | {:error, term()}
  def close(process, timeout), do: GenServer.call(process, :close, timeout + 4_000)

  @impl GenServer
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])
    policy = Keyword.fetch!(opts, :security_policy)
    cleanup_marker = cleanup_marker()

    with :ok <- validate_command(command, args, env),
         {:ok, exec_pid, os_pid} <-
           :exec.run([command | args], process_options(policy, env, cleanup_marker)) do
      {:ok,
       %__MODULE__{
         owner: owner,
         exec_pid: exec_pid,
         os_pid: os_pid,
         policy: policy,
         cleanup_marker: cleanup_marker
       }}
    else
      {:error, reason} -> {:stop, {:process_start_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:write, _data}, _from, %{closed?: true} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:write, data}, _from, state) do
    {:reply, :exec.send(state.exec_pid, data), state}
  end

  def handle_call(:close, _from, %{closed?: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state) do
    reply_stdout(state.stdout_from)
    state = %{state | stdout_from: nil, pending_stdout_bytes: 0}
    deadline = cleanup_deadline(state.policy.shutdown_timeout)
    descendants = cleanup_identities(state, deadline)
    _ = :exec.send(state.exec_pid, :eof)
    result = ensure_processes_stopped(:ok, descendants, state.cleanup_marker, deadline)

    {:stop, :normal, result, %{state | closed?: true}}
  end

  def handle_call({:output, :stdout, os_pid, data}, from, %{os_pid: os_pid} = state) do
    pending = state.pending_stdout_bytes + byte_size(data)

    if pending > state.policy.max_pending_stdout_bytes do
      deadline = cleanup_deadline(state.policy.shutdown_timeout)

      cleanup_result =
        ensure_processes_stopped(
          {:error, {:stdout_backlog_too_large, state.policy.max_pending_stdout_bytes}},
          cleanup_identities(state, deadline),
          state.cleanup_marker,
          deadline
        )

      notify_cleanup_result(state, cleanup_result)
      {:stop, :normal, :ok, %{state | closed?: true}}
    else
      send(state.owner, {:stdio_process, self(), :stdout, data})

      {:noreply, %{state | pending_stdout_bytes: pending, stdout_from: {from, byte_size(data)}}}
    end
  end

  def handle_call({:output, :stderr, os_pid, data}, _from, %{os_pid: os_pid} = state) do
    remaining = max(state.policy.max_stderr_bytes - state.stderr_bytes, 0)
    captured = if byte_size(data) <= remaining, do: data, else: binary_part(data, 0, remaining)
    if captured != "", do: send(state.owner, {:stdio_process, self(), :stderr, captured})

    stderr_bytes = min(state.stderr_bytes + byte_size(data), state.policy.max_stderr_bytes)
    action = if remaining == 0, do: {:throttle, 10}, else: :ok
    {:reply, action, %{state | stderr_bytes: stderr_bytes}}
  end

  @impl GenServer
  def handle_cast({:ack_stdout, bytes}, state) do
    reply_stdout(state.stdout_from)

    state = %{
      state
      | pending_stdout_bytes: max(state.pending_stdout_bytes - bytes, 0),
        stdout_from: nil
    }

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, os_pid, :process, exec_pid, reason}, state)
      when os_pid == state.os_pid and exec_pid == state.exec_pid do
    deadline = cleanup_deadline(state.policy.shutdown_timeout)

    cleanup_result =
      ensure_processes_stopped(
        :ok,
        cleanup_identities(state, deadline),
        state.cleanup_marker,
        deadline
      )

    notify_cleanup_failure(state, cleanup_result)
    send(state.owner, {:stdio_process, self(), :closed, normalize_exit(reason)})
    {:stop, :normal, %{state | closed?: true}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp reply_stdout(nil), do: :ok
  defp reply_stdout({from, _bytes}), do: GenServer.reply(from, :ok)

  defp notify_cleanup_result(state, {:error, {:stdout_backlog_too_large, _} = reason}) do
    send(state.owner, {:stdio_process, self(), :closed, {:protocol_violation, reason}})
  end

  defp notify_cleanup_result(state, {:error, {reason, cleanup_reason}}) do
    send(state.owner, {:stdio_process, self(), :cleanup_failed, cleanup_reason})
    send(state.owner, {:stdio_process, self(), :closed, {:protocol_violation, reason}})
  end

  defp notify_cleanup_failure(state, {:error, cleanup_reason}),
    do: send(state.owner, {:stdio_process, self(), :cleanup_failed, cleanup_reason})

  defp notify_cleanup_failure(_state, :ok), do: :ok

  defp validate_command(command, args, env)
       when is_binary(command) and is_list(args) and is_list(env) do
    cond do
      Path.type(command) != :absolute -> {:error, :absolute_command_required}
      not Enum.all?(args, &is_binary/1) -> {:error, :invalid_arguments}
      not Enum.all?(env, &valid_env?/1) -> {:error, :invalid_environment}
      true -> :ok
    end
  end

  defp validate_command(_command, _args, _env), do: {:error, :invalid_command}

  defp valid_env?({key, value}) do
    is_binary(key) and is_binary(value) and not String.contains?(key, ["=", <<0>>]) and
      not String.contains?(value, <<0>>)
  end

  defp valid_env?(_other), do: false

  defp process_options(policy, env, cleanup_marker) do
    kill_timeout_seconds = max(div(policy.shutdown_timeout + 999, 1_000), 1)

    [
      :stdin,
      {:stdout, output_device(self(), :stdout)},
      stderr_option(policy.stderr),
      :monitor,
      {:group, 0},
      :kill_group,
      {:kill_timeout, kill_timeout_seconds},
      {:env, environment(policy.environment, env, cleanup_marker)}
    ]
  end

  defp stderr_option(:capture), do: {:stderr, output_device(self(), :stderr)}
  defp stderr_option(:console), do: {:stderr, :print}
  defp stderr_option(:disable), do: {:stderr, :null}

  defp output_device(process, stream) do
    fn _stream, os_pid, data ->
      case GenServer.call(process, {:output, stream, os_pid, data}, :infinity) do
        {:throttle, milliseconds} -> Process.sleep(milliseconds)
        :ok -> :ok
      end
    end
  end

  defp environment(:replace, env, cleanup_marker), do: [:clear | env] ++ [cleanup_marker]
  defp environment(:inherit, env, cleanup_marker), do: env ++ [cleanup_marker]

  defp cleanup_marker do
    suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    {"MCP_STDIO_CLEANUP_#{suffix}", "1"}
  end

  defp normalize_exit(:normal), do: :normal
  defp normalize_exit({:exit_status, status}), do: {:exit_status, :exec.status(status)}
  defp normalize_exit(reason), do: reason

  defp descendants(root_pid, deadline) do
    %{children: children, start_times: start_times} = process_table(deadline)

    root_pid
    |> descendants_from(children)
    |> Enum.uniq()
    |> Enum.map(&{&1, Map.get(start_times, &1)})
  end

  defp cleanup_identities(state, deadline) do
    Enum.uniq(
      descendants(state.os_pid, deadline) ++ marked_processes(state.cleanup_marker, deadline)
    )
  end

  defp marked_processes({key, value}, deadline) do
    marker = key <> "=" <> value

    proc_paths("environ")
    |> Enum.reduce_while([], fn path, identities ->
      marked_process_step(path, identities, marker, deadline)
    end)
  end

  defp marked_process_step(path, identities, marker, deadline) do
    if deadline_expired?(deadline) do
      {:halt, identities}
    else
      read_marked_process(path, identities, marker)
    end
  end

  defp read_marked_process(path, identities, marker) do
    with {:ok, environment} <- File.read(path),
         true <- marker_in_environment?(environment, marker),
         pid_text <- path |> Path.dirname() |> Path.basename(),
         {pid, ""} <- Integer.parse(pid_text),
         {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         fields when is_list(fields) <- stat_fields(stat) do
      {:cont, [{pid, Enum.at(fields, 19)} | identities]}
    else
      _unavailable_or_unmarked -> {:cont, identities}
    end
  end

  defp marker_in_environment?(environment, marker) do
    environment
    |> :binary.split(<<0>>, [:global])
    |> Enum.member?(marker)
  end

  defp descendants_from(pid, children) do
    children
    |> Map.get(pid, [])
    |> Enum.flat_map(fn child -> [child | descendants_from(child, children)] end)
  end

  # Parenthood and start-time identity are taken from the same `/proc/<pid>/stat`
  # read. Collecting the identity in a second pass would let a PID recycled
  # between the two reads inherit a descendant's place in the tree, and cleanup
  # would then signal an unrelated process.
  defp process_table(deadline) do
    proc_paths("stat")
    |> Enum.reduce_while(%{children: %{}, start_times: %{}}, fn path, table ->
      process_table_step(path, table, deadline)
    end)
  end

  defp process_table_step(path, table, deadline) do
    if deadline_expired?(deadline) do
      {:halt, table}
    else
      read_process_identity(path, table)
    end
  end

  defp read_process_identity(path, table) do
    case File.read(path) do
      {:ok, stat} -> {:cont, put_process_identity(table, stat)}
      {:error, _unavailable} -> {:cont, table}
    end
  end

  defp put_process_identity(table, stat) do
    with {pid, _rest} <- Integer.parse(stat),
         fields when is_list(fields) <- stat_fields(stat),
         parent_field when is_binary(parent_field) <- Enum.at(fields, 1),
         {parent_pid, ""} <- Integer.parse(parent_field) do
      %{
        table
        | children: Map.update(table.children, parent_pid, [pid], &[pid | &1]),
          start_times: Map.put(table.start_times, pid, Enum.at(fields, 19))
      }
    else
      _unparsable -> table
    end
  end

  defp ensure_processes_stopped({:error, reason}, identities, marker, deadline) do
    case ensure_processes_stopped(:ok, identities, marker, deadline) do
      :ok -> {:error, reason}
      {:error, cleanup_reason} -> {:error, {reason, cleanup_reason}}
    end
  end

  defp ensure_processes_stopped(:ok, identities, marker, deadline) do
    identities = Enum.uniq(identities ++ marked_processes(marker, deadline))
    signal_alive(identities, :sigterm, deadline)

    term_deadline = min(deadline, now_ms() + 500)
    _ = wait_until_stopped(identities, term_deadline)
    remaining = Enum.uniq(identities ++ marked_processes(marker, deadline))
    signal_alive(remaining, :sigkill, deadline)

    if wait_until_stopped(remaining, deadline) and
         not deadline_expired?(deadline) and
         marked_processes(marker, deadline) == [] do
      :ok
    else
      {:error, :process_group_cleanup_failed}
    end
  end

  defp signal_alive(identities, signal, deadline) do
    flag = if signal == :sigterm, do: "-TERM", else: "-KILL"

    Enum.reduce_while(identities, :ok, fn {pid, _start_time} = identity, :ok ->
      if deadline_expired?(deadline) do
        {:halt, :timeout}
      else
        signal_if_alive(identity, flag, pid, deadline)
        {:cont, :ok}
      end
    end)
  end

  defp signal_if_alive(identity, flag, pid, deadline) do
    if process_alive?(identity), do: bounded_signal(flag, pid, deadline), else: :ok
  end

  defp bounded_signal(flag, pid, deadline) do
    port =
      Port.open(
        {:spawn_executable, ~c"/bin/kill"},
        [:binary, :exit_status, args: [flag, "--", Integer.to_string(pid)]]
      )

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      remaining_ms(deadline) ->
        Port.close(port)
        :timeout
    end
  end

  defp wait_until_stopped(identities, deadline) do
    wait_until_stopped(identities, deadline, Enum.any?(identities, &process_alive?/1))
  end

  defp wait_until_stopped(_pids, _deadline, false), do: true

  defp wait_until_stopped(identities, deadline, true) do
    if deadline_expired?(deadline) do
      false
    else
      Process.sleep(20)
      wait_until_stopped(identities, deadline, Enum.any?(identities, &process_alive?/1))
    end
  end

  defp cleanup_deadline(timeout), do: now_ms() + timeout
  defp deadline_expired?(deadline), do: now_ms() >= deadline
  defp remaining_ms(deadline), do: max(deadline - now_ms(), 1)
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp proc_paths(filename) do
    case File.ls("/proc") do
      {:ok, entries} ->
        entries
        |> Enum.filter(&numeric_name?/1)
        |> Enum.map(&Path.join(["/proc", &1, filename]))

      {:error, _unavailable} ->
        []
    end
  end

  defp numeric_name?(name) do
    case Integer.parse(name) do
      {_pid, ""} -> true
      _not_pid -> false
    end
  end

  defp process_alive?({pid, expected_start_time}) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> alive_identity?(stat_fields(stat), expected_start_time)
      {:error, _reason} -> false
    end
  end

  defp alive_identity?([state | _rest] = fields, expected_start_time),
    do: state != "Z" and Enum.at(fields, 19) == expected_start_time

  defp alive_identity?(_fields, _expected_start_time), do: false

  @doc """
  Reports whether an OS process is still running, treating an unreaped zombie
  as stopped.

  Exposed so cleanup probes assert liveness the same way cleanup does, rather
  than reimplementing `/proc` parsing.
  """
  @spec os_process_alive?(pos_integer()) :: boolean()
  def os_process_alive?(pid) when is_integer(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> running_stat?(stat)
      {:error, _reason} -> false
    end
  end

  defp running_stat?(stat) do
    case stat_fields(stat) do
      [state | _rest] -> state != "Z"
      _unparsable -> false
    end
  end

  # `/proc/<pid>/stat` field 2 is the parenthesised executable name and may
  # itself contain spaces and parentheses, so the fields after it are only
  # addressable from the final ") " in the line. The returned list starts at
  # field 3 (state), which puts ppid at index 1 and starttime at index 19.
  defp stat_fields(stat) do
    case :binary.matches(stat, ") ") |> List.last() do
      {offset, 2} ->
        stat
        |> binary_part(offset + 2, byte_size(stat) - offset - 2)
        |> String.split()

      nil ->
        nil
    end
  end
end
