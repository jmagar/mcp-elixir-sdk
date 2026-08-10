defmodule MCP.Transport.Stdio do
  @moduledoc """
  Stdio transport for MCP.

  Communicates via newline-delimited JSON-RPC over stdin/stdout.

  ## Client mode

  Launches a subprocess via an Erlang Port. Messages are written as
  JSON + newline to the subprocess's stdin, and read as newline-delimited
  JSON from stdout. Stderr goes to the parent process's stderr.

  ## Server mode

  Reads from the process's own stdin and writes to stdout. Used when
  this Elixir process IS the MCP server subprocess.

  ## Options

    * `:owner` (required) — pid to receive `{:mcp_message, map}` and
      `{:mcp_transport_closed, reason}` messages
    * `:command` — path to executable (client mode). When provided, a
      subprocess is spawned.
    * `:args` — arguments for the command (default: `[]`)
    * `:env` — environment variables as `[{String.t(), String.t()}]`
    * `:mode` — `:client` (default when `:command` given) or `:server`
  """

  use GenServer

  require Logger

  @behaviour MCP.Transport

  alias MCP.Protocol
  alias MCP.Transport.Stdio.Process, as: StdioProcess
  alias MCP.Transport.Stdio.SecurityPolicy

  defstruct [
    :owner,
    :mode,
    :process,
    :security_policy,
    :io_device,
    :reader_pid,
    buffer: "",
    stderr_bytes: 0,
    stderr_limit_reported?: false
  ]

  # --- Public API (Transport behaviour) ---

  @impl MCP.Transport
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl MCP.Transport
  def send_message(pid, message) when is_map(message) do
    GenServer.call(pid, {:send_message, message})
  end

  @impl MCP.Transport
  def close(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _ -> :ok
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    mode = determine_mode(opts)

    with {:ok, security_policy} <- security_policy(opts) do
      state = %__MODULE__{owner: owner, mode: mode, security_policy: security_policy}

      case mode do
        :client -> init_client(state, opts)
        :server -> init_server(state)
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:send_message, message}, _from, state) do
    case do_send(state, message) do
      :ok -> {:reply, :ok, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:close, _from, state) do
    case do_close(state) do
      :ok -> {:stop, :normal, :ok, %{state | process: nil}}
      {:error, reason} -> {:stop, {:shutdown_failed, reason}, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({:stdio_process, process, :stdout, data}, %{process: process} = state) do
    consume_stdout(state, data)
  end

  def handle_info({:stdio_process, process, :stderr, data}, %{process: process} = state) do
    {:noreply, consume_stderr(state, data)}
  end

  def handle_info({:stdio_process, process, :closed, reason}, %{process: process} = state) do
    send(state.owner, {:mcp_transport_closed, reason})
    {:stop, :normal, %{state | process: nil}}
  end

  def handle_info(:drain_stdout, state) do
    consume_stdout(%{state | buffer: ""}, state.buffer)
  end

  # Server mode: stdin reader sends us lines
  def handle_info({:stdio_line, line}, state) do
    case Jason.decode(line) do
      {:ok, decoded} ->
        send(state.owner, {:mcp_message, decoded})

      {:error, reason} ->
        Logger.warning("MCP Stdio: failed to decode JSON from stdin: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(:stdio_eof, state) do
    send(state.owner, {:mcp_transport_closed, :eof})
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Logger.debug("MCP Stdio: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    do_close(state)
    :ok
  end

  # --- Private helpers ---

  defp determine_mode(opts) do
    cond do
      Keyword.has_key?(opts, :command) -> :client
      Keyword.get(opts, :mode) == :server -> :server
      true -> :server
    end
  end

  defp init_client(state, opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])

    case StdioProcess.start_link(
           owner: self(),
           command: command,
           args: args,
           env: env,
           security_policy: state.security_policy
         ) do
      {:ok, process} -> {:ok, %{state | process: process}}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp init_server(state) do
    transport = self()

    pid =
      spawn_link(fn ->
        stdio_read_loop(transport)
      end)

    {:ok, %{state | reader_pid: pid}}
  end

  defp stdio_read_loop(transport) do
    case :io.get_line(:standard_io, ~c"") do
      :eof ->
        send(transport, :stdio_eof)

      {:error, _reason} ->
        send(transport, :stdio_eof)

      data when is_binary(data) ->
        line = String.trim_trailing(data, "\n")

        if line != "" do
          send(transport, {:stdio_line, line})
        end

        stdio_read_loop(transport)

      data when is_list(data) ->
        line = data |> IO.chardata_to_string() |> String.trim_trailing("\n")

        if line != "" do
          send(transport, {:stdio_line, line})
        end

        stdio_read_loop(transport)
    end
  end

  defp do_send(%{mode: :client, process: process}, message) when is_pid(process) do
    json = Jason.encode!(message)
    StdioProcess.write(process, [json, "\n"])
  rescue
    e -> {:error, e}
  end

  defp do_send(%{mode: :server}, message) do
    json = Jason.encode!(message)
    IO.write(:stdio, [json, "\n"])
    :ok
  rescue
    e -> {:error, e}
  end

  defp do_close(%{mode: :client, process: process, security_policy: policy})
       when is_pid(process) do
    StdioProcess.close(process, policy.shutdown_timeout)
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, reason -> {:error, {:process_shutdown_failed, reason}}
  end

  defp do_close(%{mode: :server, reader_pid: pid}) when is_pid(pid) do
    Process.exit(pid, :shutdown)
  end

  defp do_close(_state), do: :ok

  defp security_policy(opts) do
    case Keyword.get(opts, :security_policy) do
      nil -> {:ok, SecurityPolicy.default()}
      %SecurityPolicy{} = policy -> {:ok, policy}
      policy_opts when is_list(policy_opts) -> SecurityPolicy.new(policy_opts)
      invalid -> {:error, {:invalid_security_policy, invalid}}
    end
  end

  defp consume_stdout(state, data) do
    combined = state.buffer <> data

    case consume_frames(combined, state.security_policy, 0, []) do
      {:ok, messages, remaining, more?} ->
        Enum.each(messages, &send(state.owner, {:mcp_message, &1}))

        if more?, do: send(self(), :drain_stdout)
        {:noreply, %{state | buffer: remaining}}

      {:error, reason} ->
        send(state.owner, {:mcp_transport_closed, {:protocol_violation, reason}})
        {:stop, :normal, state}
    end
  end

  defp consume_frames(buffer, policy, count, messages)
       when count >= policy.max_frames_per_turn do
    {:ok, Enum.reverse(messages), buffer, :binary.match(buffer, "\n") != :nomatch}
  end

  defp consume_frames(buffer, policy, count, messages) do
    case :binary.match(buffer, "\n") do
      {line_size, 1} when line_size > policy.max_frame_bytes ->
        {:error, {:frame_too_large, policy.max_frame_bytes}}

      {line_size, 1} ->
        <<line::binary-size(line_size), _newline, rest::binary>> = buffer

        case decode_protocol_line(line) do
          {:ok, decoded} -> consume_frames(rest, policy, count + 1, [decoded | messages])
          {:error, reason} -> {:error, reason}
        end

      :nomatch when byte_size(buffer) > policy.max_frame_bytes ->
        {:error, {:frame_too_large, policy.max_frame_bytes}}

      :nomatch ->
        {:ok, Enum.reverse(messages), buffer, false}
    end
  end

  defp decode_protocol_line(line) do
    with {:ok, decoded} when is_map(decoded) <- Jason.decode(line),
         {:ok, _classified} <- Protocol.decode_message(decoded) do
      {:ok, decoded}
    else
      {:ok, decoded} -> {:error, {:non_protocol_json, decoded}}
      {:error, %MCP.Protocol.Error{} = error} -> {:error, {:invalid_json_rpc, error.code}}
      {:error, reason} -> {:error, {:malformed_json, reason}}
    end
  end

  defp consume_stderr(%{security_policy: %{stderr: :capture}} = state, data) do
    remaining = max(state.security_policy.max_stderr_bytes - state.stderr_bytes, 0)
    captured = binary_part(data, 0, min(byte_size(data), remaining))
    if captured != "", do: send(state.owner, {:mcp_transport_stderr, captured})

    total = state.stderr_bytes + byte_size(data)

    if total > state.security_policy.max_stderr_bytes and not state.stderr_limit_reported? do
      Logger.warning("MCP Stdio: stderr diagnostic limit reached; further output is discarded")
    end

    %{
      state
      | stderr_bytes: min(total, state.security_policy.max_stderr_bytes),
        stderr_limit_reported?:
          state.stderr_limit_reported? or total > state.security_policy.max_stderr_bytes
    }
  end

  defp consume_stderr(state, _data), do: state
end
