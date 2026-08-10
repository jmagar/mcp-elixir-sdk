defmodule MCP.Transport.Stdio.Process do
  @moduledoc false

  use GenServer

  defstruct [:owner, :exec_pid, :os_pid, :policy, closed?: false]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec write(pid(), iodata()) :: :ok | {:error, term()}
  def write(process, data), do: GenServer.call(process, {:write, IO.iodata_to_binary(data)})

  @spec close(pid(), timeout()) :: :ok | {:error, term()}
  def close(process, timeout), do: GenServer.call(process, :close, timeout + 4_000)

  @impl GenServer
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])
    policy = Keyword.fetch!(opts, :security_policy)

    with :ok <- validate_command(command, args, env),
         {:ok, exec_pid, os_pid} <-
           :exec.run([command | args], process_options(policy, env)) do
      {:ok, %__MODULE__{owner: owner, exec_pid: exec_pid, os_pid: os_pid, policy: policy}}
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
    descendants = descendants(state.os_pid)
    _ = :exec.send(state.exec_pid, :eof)

    result =
      case :exec.stop_and_wait(state.exec_pid, state.policy.shutdown_timeout + 1_000) do
        {:error, :timeout} -> {:error, :process_group_cleanup_failed}
        {:error, :not_found} -> :ok
        {:error, reason} -> {:error, {:process_shutdown_failed, reason}}
        _exit_status -> :ok
      end
      |> ensure_descendants_stopped(descendants, state.policy.shutdown_timeout)

    {:stop, :normal, result, %{state | closed?: true}}
  end

  @impl GenServer
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state) do
    send(state.owner, {:stdio_process, self(), :stdout, data})
    {:noreply, state}
  end

  def handle_info({:stderr, os_pid, data}, %{os_pid: os_pid} = state) do
    send(state.owner, {:stdio_process, self(), :stderr, data})
    {:noreply, state}
  end

  def handle_info({:DOWN, os_pid, :process, exec_pid, reason}, state)
      when os_pid == state.os_pid and exec_pid == state.exec_pid do
    send(state.owner, {:stdio_process, self(), :closed, normalize_exit(reason)})
    {:stop, :normal, %{state | closed?: true}}
  end

  def handle_info(_message, state), do: {:noreply, state}

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

  defp process_options(policy, env) do
    kill_timeout_seconds = max(div(policy.shutdown_timeout + 999, 1_000), 1)

    [
      :stdin,
      {:stdout, self()},
      stderr_option(policy.stderr),
      :monitor,
      {:group, 0},
      :kill_group,
      {:kill_timeout, kill_timeout_seconds},
      {:env, environment(policy.environment, env)}
    ]
  end

  defp stderr_option(:capture), do: {:stderr, self()}
  defp stderr_option(:console), do: {:stderr, :print}
  defp stderr_option(:disable), do: {:stderr, :null}

  defp environment(:replace, env), do: [:clear | env]
  defp environment(:inherit, env), do: env

  defp normalize_exit(:normal), do: :normal
  defp normalize_exit({:exit_status, status}), do: {:exit_status, :exec.status(status)}
  defp normalize_exit(reason), do: reason

  defp descendants(root_pid) do
    process_table = process_table()

    descendants_from(root_pid, process_table)
    |> Enum.uniq()
    |> Enum.map(&{&1, process_start_time(&1)})
  end

  defp descendants_from(pid, process_table) do
    process_table
    |> Map.get(pid, [])
    |> Enum.flat_map(fn child -> [child | descendants_from(child, process_table)] end)
  end

  defp process_table do
    "/proc/[0-9]*/status"
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn path, table ->
      with {:ok, status} <- File.read(path),
           {pid, ""} <- status_field_integer(status, "Pid:"),
           {parent_pid, ""} <- status_field_integer(status, "PPid:") do
        Map.update(table, parent_pid, [pid], &[pid | &1])
      else
        _unavailable -> table
      end
    end)
  end

  defp status_field_integer(status, field) do
    status
    |> String.split("\n")
    |> Enum.find_value(:error, fn line ->
      case String.split(line, ~r/\s+/, trim: true) do
        [^field, value] -> Integer.parse(value)
        _other -> nil
      end
    end)
  end

  defp ensure_descendants_stopped({:error, reason}, descendants, timeout) do
    case ensure_descendants_stopped(:ok, descendants, timeout) do
      :ok -> {:error, reason}
      {:error, cleanup_reason} -> {:error, {reason, cleanup_reason}}
    end
  end

  defp ensure_descendants_stopped(:ok, [], _timeout), do: :ok

  defp ensure_descendants_stopped(:ok, descendants, timeout) do
    signal_alive(descendants, :sigterm)

    if wait_until_stopped(descendants, min(timeout, 1_000)) do
      :ok
    else
      signal_alive(descendants, :sigkill)

      if wait_until_stopped(descendants, 1_000) do
        :ok
      else
        {:error, :process_group_cleanup_failed}
      end
    end
  end

  defp signal_alive(identities, signal) do
    flag = if signal == :sigterm, do: "-TERM", else: "-KILL"

    Enum.each(identities, fn {pid, _start_time} = identity ->
      if process_alive?(identity) do
        _ = System.cmd("/bin/kill", [flag, "--", Integer.to_string(pid)], stderr_to_stdout: true)
      end
    end)
  end

  defp wait_until_stopped(identities, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_until_stopped(identities, deadline, Enum.any?(identities, &process_alive?/1))
  end

  defp wait_until_stopped(_pids, _deadline, false), do: true

  defp wait_until_stopped(identities, deadline, true) do
    if System.monotonic_time(:millisecond) >= deadline do
      false
    else
      Process.sleep(20)
      wait_until_stopped(identities, deadline, Enum.any?(identities, &process_alive?/1))
    end
  end

  defp process_alive?({pid, expected_start_time}) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        not zombie_stat?(stat) and process_start_time(stat) == expected_start_time

      {:error, _reason} ->
        false
    end
  end

  defp zombie_stat?(stat) do
    case :binary.matches(stat, ") ") |> List.last() do
      {offset, 2} -> binary_part(stat, offset + 2, 1) == "Z"
      nil -> false
    end
  end

  defp process_start_time(pid) when is_integer(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> process_start_time(stat)
      {:error, _reason} -> nil
    end
  end

  defp process_start_time(stat) do
    case :binary.matches(stat, ") ") |> List.last() do
      {offset, 2} ->
        stat
        |> binary_part(offset + 2, byte_size(stat) - offset - 2)
        |> String.split()
        |> Enum.at(19)

      nil ->
        nil
    end
  end
end
