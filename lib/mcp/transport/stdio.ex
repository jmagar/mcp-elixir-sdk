defmodule MCP.Transport.Stdio do
  @moduledoc """
  Stdio transport for MCP.

  Communicates via newline-delimited JSON-RPC over stdin/stdout.

  ## Client mode

  Delegates subprocess supervision to an internal process wrapper. Messages are written as
  JSON + newline to the subprocess's stdin, and read as newline-delimited
  JSON from stdout. Stderr is disabled by default and can be bounded and captured by policy.

  ## Server mode

  Reads from the process's own stdin and writes to stdout. Used when
  this Elixir process IS the MCP server subprocess.

  ## Options

    * `:owner` (required) — pid to receive `{:mcp_message, map}` and
      `{:mcp_transport_closed, reason}` and optional `{:mcp_transport_stderr, data}` messages
    * `:command` — path to executable (client mode). When provided, a
      subprocess is spawned.
    * `:args` — arguments for the command (default: `[]`)
    * `:env` — environment variables as `[{String.t(), String.t()}]`
    * `:mode` — `:client` (default when `:command` given) or `:server`
    * `:security_policy` — a `SecurityPolicy` or keyword options controlling bounds and cleanup
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
    stderr_limit_reported?: false,
    closing_reason: :none
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
    # Every inner shutdown path is bounded: StdioProcess.close/2 waits at most
    # shutdown_timeout + 4_000 ms, and the descendant sweep has its own budget.
    # A shorter call timeout here would report {:close_failed, :timeout} to the
    # caller while process-tree cleanup was still running correctly.
    GenServer.call(pid, :close, :infinity)
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, reason -> {:error, {:close_failed, reason}}
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    mode = determine_mode(opts)
    init_with_policy(owner, mode, opts)
  end

  defp init_with_policy(owner, mode, opts) do
    case security_policy(opts) do
      {:ok, security_policy} ->
        state = %__MODULE__{owner: owner, mode: mode, security_policy: security_policy}

        case mode do
          :client -> init_client(state, opts)
          :server -> init_server(state)
        end

      {:error, reason} ->
        {:stop, reason}
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
    result = consume_stdout(state, data)
    StdioProcess.ack_stdout(process, byte_size(data))
    result
  end

  def handle_info({:stdio_process, process, :stderr, data}, %{process: process} = state) do
    {:noreply, consume_stderr(state, data)}
  end

  def handle_info(
        {:stdio_process, process, :cleanup_failed, reason},
        %{process: process} = state
      ) do
    Logger.error("MCP Stdio cleanup failed after subprocess exit: #{inspect(reason)}")
    send(state.owner, {:mcp_transport_cleanup_failed, reason})
    {:noreply, state}
  end

  def handle_info({:stdio_process, process, :closed, reason}, %{process: process} = state) do
    # A subprocess that writes a burst and exits leaves the tail of that burst
    # buffered behind a frame-turn boundary, and this notification is already
    # queued ahead of the self-scheduled drain. Rather than flushing the whole
    # buffer here — which would deliver an unbounded number of frames in one
    # turn — the close is deferred until the remaining frames have drained under
    # the usual per-turn limit.
    finish_or_defer_close(%{state | process: nil}, reason)
  end

  def handle_info(:drain_stdout, state) do
    consume_stdout(%{state | buffer: ""}, state.buffer)
  end

  def handle_info({:stdio_chunk, reader, data}, %{mode: :server, reader_pid: reader} = state) do
    result = consume_stdout(state, data)
    send(reader, {:stdio_chunk_ack, self()})
    result
  end

  def handle_info(:stdio_eof, %{mode: :server} = state), do: finish_or_defer_close(state, :eof)

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
    case IO.binread(:standard_io, 4_096) do
      :eof ->
        send(transport, :stdio_eof)

      {:error, _reason} ->
        send(transport, :stdio_eof)

      data when is_binary(data) ->
        send(transport, {:stdio_chunk, self(), data})

        receive do
          {:stdio_chunk_ack, ^transport} -> stdio_read_loop(transport)
        end
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
    :ok
  end

  defp do_close(_state), do: :ok

  defp security_policy(opts) do
    case Keyword.get(opts, :security_policy) do
      nil -> {:ok, SecurityPolicy.default()}
      %SecurityPolicy{} = policy -> SecurityPolicy.new(policy)
      policy_opts when is_list(policy_opts) -> SecurityPolicy.new(policy_opts)
      invalid -> {:error, {:invalid_security_policy, invalid}}
    end
  end

  defp consume_stdout(state, data) do
    combined = state.buffer <> data

    if byte_size(combined) > state.security_policy.max_pending_stdout_bytes do
      fail_protocol(
        state,
        {:stdout_backlog_too_large, state.security_policy.max_pending_stdout_bytes},
        []
      )
    else
      consume_stdout_frames(state, combined)
    end
  end

  defp consume_stdout_frames(state, combined) do
    case consume_frames(combined, state.security_policy, 0, []) do
      {:ok, messages, remaining, more?} ->
        Enum.each(messages, &send(state.owner, {:mcp_message, &1}))
        state = %{state | buffer: remaining}
        continue_after_stdout_turn(state, remaining, more?)

      {:error, reason, messages} ->
        fail_protocol(state, reason, messages)
    end
  end

  # Queued immediately: the message lands behind everything already in the
  # mailbox, preserving the frame-turn yield without adding latency or letting
  # a queued close notification overtake the drain.
  defp continue_after_stdout_turn(state, _remaining, true) do
    send(self(), :drain_stdout)
    {:noreply, state}
  end

  defp continue_after_stdout_turn(%{closing_reason: :none} = state, _remaining, false),
    do: {:noreply, state}

  defp continue_after_stdout_turn(state, "", false),
    do: emit_close(state, state.closing_reason)

  defp continue_after_stdout_turn(state, _remaining, false),
    do: emit_close(state, {:protocol_violation, :truncated_frame})

  defp fail_protocol(state, reason, messages) do
    Enum.each(messages, &send(state.owner, {:mcp_message, &1}))
    close_result = do_close(state)

    if match?({:error, _}, close_result) do
      {:error, cleanup_reason} = close_result

      Logger.error(
        "MCP Stdio cleanup failed after protocol violation: #{inspect(cleanup_reason)}"
      )

      send(state.owner, {:mcp_transport_cleanup_failed, cleanup_reason})
    end

    send(state.owner, {:mcp_transport_closed, {:protocol_violation, reason}})

    {:stop, :normal, state}
  end

  defp finish_or_defer_close(%{buffer: ""} = state, reason), do: emit_close(state, reason)

  defp finish_or_defer_close(state, reason) do
    send(self(), :drain_stdout)
    {:noreply, %{state | closing_reason: reason}}
  end

  defp emit_close(state, reason) do
    send(state.owner, {:mcp_transport_closed, reason})
    {:stop, :normal, %{state | closing_reason: :none}}
  end

  defp consume_frames(buffer, policy, count, messages)
       when count >= policy.max_frames_per_turn do
    {:ok, Enum.reverse(messages), buffer, :binary.match(buffer, "\n") != :nomatch}
  end

  defp consume_frames(buffer, policy, count, messages) do
    case :binary.match(buffer, "\n") do
      {line_size, 1} when line_size > policy.max_frame_bytes ->
        {:error, {:frame_too_large, policy.max_frame_bytes}, Enum.reverse(messages)}

      {line_size, 1} ->
        <<line::binary-size(^line_size), _newline, rest::binary>> = buffer

        case decode_protocol_line(line) do
          {:ok, decoded} -> consume_frames(rest, policy, count + 1, [decoded | messages])
          {:error, reason} -> {:error, reason, Enum.reverse(messages)}
        end

      :nomatch when byte_size(buffer) > policy.max_frame_bytes ->
        {:error, {:frame_too_large, policy.max_frame_bytes}, Enum.reverse(messages)}

      :nomatch ->
        {:ok, Enum.reverse(messages), buffer, false}
    end
  end

  defp decode_protocol_line(line) do
    with {:ok, decoded} when is_map(decoded) <- Jason.decode(line),
         {:ok, _classified} <- Protocol.decode_message(decoded) do
      {:ok, decoded}
    else
      {:ok, _decoded} -> {:error, :non_protocol_json}
      {:error, %MCP.Protocol.Error{} = error} -> {:error, {:invalid_json_rpc, error.code}}
      {:error, _reason} -> {:error, :malformed_json}
    end
  end

  defp consume_stderr(%{security_policy: %{stderr: :capture}} = state, data) do
    remaining = max(state.security_policy.max_stderr_bytes - state.stderr_bytes, 0)
    captured = binary_prefix(data, remaining)
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

  defp binary_prefix(_data, 0), do: ""
  defp binary_prefix(data, limit) when byte_size(data) <= limit, do: data
  defp binary_prefix(data, limit), do: binary_part(data, 0, limit)
end
