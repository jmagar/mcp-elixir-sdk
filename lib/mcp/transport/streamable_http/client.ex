defmodule MCP.Transport.StreamableHTTP.Client do
  @moduledoc """
  Streamable HTTP client transport for MCP.

  Sends JSON-RPC messages via HTTP POST and receives responses as either
  `application/json` or `text/event-stream` (SSE). Optionally opens a
  GET SSE stream for server-initiated messages.

  ## Options

    * `:owner` (required) — pid to receive `{:mcp_message, map}` and
      `{:mcp_transport_closed, reason}` messages
    * `:url` (required) — the MCP endpoint URL (e.g., "http://localhost:8080/mcp")
    * `:headers` — extra HTTP headers to include on all requests
    * `:protocol_version` — MCP protocol version (default: the stateless core's)

  ## Stateless (2026-07-28)

  There is **no session**: the client sends no `MCP-Session-Id` and issues no
  DELETE on close (SEP-2567). Every POST is self-contained — the per-request
  `_meta` (protocol version, client identity/capabilities) is placed on the
  JSON-RPC message by `MCP.Client`, so any server instance can service it.

  ## Stateful compatibility (2025-11-25)

  An initialize response binds `Mcp-Session-Id`. Later requests reuse it, a
  supervised GET SSE listener receives server messages, and close performs a
  best-effort session DELETE.
  """

  use GenServer

  require Logger

  alias MCP.Protocol.ToolRouting
  alias MCP.Transport.SSE
  alias MCP.Transport.StreamableHTTP.ResponseReader
  alias MCP.Transport.StreamableHTTP.SecurityPolicy

  @behaviour MCP.Transport

  @protocol_version "2026-07-28"
  @default_legacy_sse_retry_limit 3
  @default_legacy_sse_retry_backoff 50
  @default_legacy_sse_retry_max_backoff 1_000

  defstruct [
    :owner,
    :owner_ref,
    :url,
    :endpoint,
    :security_policy,
    :protocol_version,
    :session_id,
    :extra_headers,
    :task_supervisor,
    :legacy_sse_task,
    :legacy_sse_ref,
    :legacy_sse_retry_limit,
    :legacy_sse_retry_backoff,
    :legacy_sse_retry_max_backoff,
    post_tasks: %{},
    subscriptions: %{}
  ]

  # --- Public API (Transport behaviour) ---

  @impl MCP.Transport
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl MCP.Transport
  def send_message(pid, message) when is_map(message) do
    send_message(pid, message, [])
  end

  @impl MCP.Transport
  def send_message(pid, message, opts) when is_map(message) and is_list(opts) do
    GenServer.call(pid, {:send_message, message, opts}, 60_000)
  end

  @impl MCP.Transport
  def close(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, reason -> {:error, {:close_failed, reason}}
  end

  @doc false
  def reset_session(pid) do
    GenServer.call(pid, :reset_session)
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, reason -> {:error, {:reset_session_failed, reason}}
  end

  @impl MCP.Transport
  def open_subscription(pid, message, opts \\ []) when is_map(message) and is_list(opts) do
    GenServer.call(pid, {:open_subscription, message, opts}, 60_000)
  end

  @impl MCP.Transport
  def cancel_subscription(pid, request_id) do
    GenServer.call(pid, {:cancel_subscription, request_id})
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, reason -> {:error, {:cancel_subscription_failed, reason}}
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    url = Keyword.fetch!(opts, :url)
    protocol_version = Keyword.get(opts, :protocol_version, @protocol_version)
    extra_headers = Keyword.get(opts, :headers, [])

    with {:ok, security_policy} <- security_policy(opts),
         {:ok, endpoint} <- SecurityPolicy.validate_url(security_policy, url),
         nil <- reserved_extra_header(extra_headers),
         {:ok, task_supervisor} <- Task.Supervisor.start_link() do
      state = %__MODULE__{
        owner: owner,
        owner_ref: Process.monitor(owner),
        url: url,
        endpoint: URI.to_string(endpoint),
        security_policy: security_policy,
        protocol_version: protocol_version,
        extra_headers: extra_headers,
        task_supervisor: task_supervisor,
        legacy_sse_retry_limit:
          Keyword.get(opts, :legacy_sse_retry_limit, @default_legacy_sse_retry_limit),
        legacy_sse_retry_backoff:
          Keyword.get(opts, :legacy_sse_retry_backoff, @default_legacy_sse_retry_backoff),
        legacy_sse_retry_max_backoff:
          Keyword.get(
            opts,
            :legacy_sse_retry_max_backoff,
            @default_legacy_sse_retry_max_backoff
          )
      }

      {:ok, state}
    else
      name when is_binary(name) -> {:stop, {:reserved_extra_header, name}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:send_message, message, opts}, from, state) do
    case build_headers(state, message, opts) do
      {:ok, headers} -> start_post_task(state, from, message, headers)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:open_subscription, message, opts}, _from, state) do
    id = Map.get(message, "id")

    cond do
      not (is_binary(id) or is_integer(id)) ->
        {:reply, {:error, :invalid_subscription_id}, state}

      Map.has_key?(state.subscriptions, id) ->
        {:reply, {:error, :duplicate_subscription_id}, state}

      true ->
        case build_headers(state, message, opts) do
          {:ok, headers} -> start_subscription_task(state, id, message, headers)
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:cancel_subscription, request_id}, _from, state) do
    case Map.pop(state.subscriptions, request_id) do
      {nil, _subscriptions} ->
        {:reply, :ok, state}

      {subscription, subscriptions} ->
        Process.demonitor(subscription.monitor_ref, [:flush])
        _ = Task.Supervisor.terminate_child(state.task_supervisor, subscription.task)
        {:reply, :ok, %{state | subscriptions: subscriptions}}
    end
  end

  def handle_call({:bind_session, session_id, protocol_version}, _from, state)
      when is_binary(session_id) and is_binary(protocol_version) do
    state = %{state | session_id: session_id, protocol_version: protocol_version}
    {:reply, :ok, start_legacy_sse_listener(state)}
  end

  def handle_call(:reset_session, _from, state) do
    asynchronously_terminate_legacy_session(state)
    {:reply, :ok, clear_legacy_session(state)}
  end

  def handle_call(:close, _from, state) do
    result = do_close(state, :synchronous)

    {:stop, :normal, result,
     %{state | session_id: nil, legacy_sse_task: nil, legacy_sse_ref: nil}}
  rescue
    exception -> transport_close_failure(state, :error, exception, __STACKTRACE__)
  catch
    kind, reason -> transport_close_failure(state, kind, reason, __STACKTRACE__)
  end

  @impl GenServer
  def handle_info({:sse_event, event}, state) do
    # SSE event received from a background stream (GET or POST SSE response)
    case Map.get(event, :data) do
      nil ->
        {:noreply, state}

      "" ->
        # Priming event with empty data — ignore
        {:noreply, state}

      data ->
        case Jason.decode(data) do
          {:ok, decoded} ->
            send(state.owner, {:mcp_message, decoded})
            {:noreply, state}

          {:error, reason} ->
            send(state.owner, {:mcp_transport_closed, {:invalid_sse_json, reason}})
            {:stop, {:invalid_sse_json, reason}, state}
        end
    end
  end

  def handle_info({:sse_stream_closed, reason}, state) do
    Logger.debug("MCP StreamableHTTP Client: SSE stream closed: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:subscription_stream_message, id, stream, delivery_ref, message}, state) do
    if Map.has_key?(state.subscriptions, id) do
      send(
        state.owner,
        {:mcp_subscription_message, self(), stream, delivery_ref, message}
      )
    else
      send(stream, {:subscription_delivery_ack, delivery_ref})
    end

    {:noreply, state}
  end

  def handle_info({:subscription_stream_closed, id, reason}, state) do
    case Map.pop(state.subscriptions, id) do
      {nil, _subscriptions} ->
        {:noreply, state}

      {subscription, subscriptions} ->
        Process.demonitor(subscription.monitor_ref, [:flush])
        send(state.owner, {:mcp_subscription_transport_closed, id, reason})
        {:noreply, %{state | subscriptions: subscriptions}}
    end
  end

  def handle_info({:legacy_sse_response, body}, state) when is_binary(body) do
    {:ok, state} = parse_sse_body(state, body)
    {:noreply, state}
  end

  def handle_info({:legacy_sse_stopped, task, reason}, %{legacy_sse_task: task} = state) do
    Process.demonitor(state.legacy_sse_ref, [:flush])
    state = %{state | legacy_sse_task: nil, legacy_sse_ref: nil}
    state = if reason == :session_expired, do: clear_legacy_session(state), else: state
    send(state.owner, {:mcp_legacy_sse_failed, reason})
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.post_tasks, ref) do
      {nil, _post_tasks} ->
        {:noreply, state}

      {operation, post_tasks} ->
        Process.demonitor(ref, [:flush])
        Process.demonitor(operation.caller_ref, [:flush])
        GenServer.reply(operation.from, normalize_post_result(result))

        state =
          if result == {:error, :session_expired},
            do: clear_legacy_session(state),
            else: state

        {:noreply, %{state | post_tasks: post_tasks}}
    end
  end

  def handle_info({:EXIT, owner, _reason}, %{owner: owner} = state) do
    do_close(state)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, owner, _reason}, %{owner: owner, owner_ref: ref} = state) do
    do_close(state)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, task, reason}, state) do
    cond do
      ref == state.legacy_sse_ref and task == state.legacy_sse_task ->
        if reason not in [:normal, :shutdown] do
          Logger.warning("MCP legacy SSE listener stopped: #{inspect(reason)}")
        end

        {:noreply, %{state | legacy_sse_task: nil, legacy_sse_ref: nil}}

      Map.has_key?(state.post_tasks, ref) ->
        fail_post_task(state, ref, reason)

      operation = post_task_by_caller_ref(state.post_tasks, ref, task) ->
        _ = Task.Supervisor.terminate_child(state.task_supervisor, operation.task_pid)
        Process.demonitor(operation.task_ref, [:flush])
        {:noreply, %{state | post_tasks: Map.delete(state.post_tasks, operation.task_ref)}}

      subscription = subscription_by_monitor(state.subscriptions, ref, task) ->
        {id, _subscription} = subscription
        send(state.owner, {:mcp_subscription_transport_closed, id, reason})
        {:noreply, %{state | subscriptions: Map.delete(state.subscriptions, id)}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("MCP StreamableHTTP Client: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    do_close(state)
    :ok
  end

  # --- Private helpers ---

  defp security_policy(opts) do
    case Keyword.get(opts, :security_policy) do
      nil -> {:ok, SecurityPolicy.default()}
      %SecurityPolicy{} = policy -> {:ok, policy}
      policy_opts when is_list(policy_opts) -> SecurityPolicy.new(policy_opts)
      invalid -> {:error, {:invalid_security_policy, invalid}}
    end
  end

  defp start_post_task(state, from, message, headers) do
    transport = self()

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        post(transport, state, message, headers)
      end)

    caller_ref = Process.monitor(elem(from, 0))

    operation = %{
      from: from,
      caller_ref: caller_ref,
      task_ref: task.ref,
      task_pid: task.pid
    }

    {:noreply, %{state | post_tasks: Map.put(state.post_tasks, task.ref, operation)}}
  end

  defp normalize_post_result({:ok, _state}), do: :ok
  defp normalize_post_result({:error, _reason} = error), do: error
  defp normalize_post_result(other), do: {:error, {:invalid_post_result, other}}

  defp fail_post_task(state, ref, reason) do
    {operation, post_tasks} = Map.pop(state.post_tasks, ref)
    Process.demonitor(operation.caller_ref, [:flush])
    GenServer.reply(operation.from, {:error, {:post_task_exit, reason}})
    {:noreply, %{state | post_tasks: post_tasks}}
  end

  defp post(transport, state, message, headers) do
    body = Jason.encode!(message)

    case ResponseReader.request(
           [method: :post, url: state.endpoint, body: body, headers: headers],
           state.security_policy
         ) do
      {:ok, %Req.Response{status: status, headers: resp_headers}, resp_body}
      when status in [200, 201] ->
        bind_response_session(transport, message, state.protocol_version, resp_headers)
        content_type = get_content_type(resp_headers)

        cond do
          String.contains?(content_type, "text/event-stream") ->
            # Parse SSE events from the response body
            parse_sse_body(state, resp_body)

          String.contains?(content_type, "application/json") ->
            # Single JSON response
            deliver_json_response(state, resp_body)

          true ->
            {:error, {:unexpected_content_type, content_type}}
        end

      {:ok, %Req.Response{status: 202}, _body} ->
        # Accepted (notification/response acknowledged)
        {:ok, state}

      {:ok, %Req.Response{status: status, headers: resp_headers}, resp_body} ->
        handle_non_success_response(state, status, resp_headers, resp_body)

      {:error, reason} ->
        Logger.warning("MCP StreamableHTTP Client: POST failed: #{inspect(reason)}")

        {:error, reason}
    end
  end

  defp handle_non_success_response(state, status, headers, body) do
    Logger.warning("MCP StreamableHTTP Client: HTTP #{status}: #{inspect(body)}")

    cond do
      status == 404 and
          (is_binary(state.session_id) or state.protocol_version != @protocol_version) ->
        {:error, :session_expired}

      String.contains?(get_content_type(headers), "text/event-stream") ->
        deliver_sse_error_response(state, status, body)

      true ->
        deliver_json_error_response(state, status, body)
    end
  end

  defp json_rpc_error_response?(body) when is_map(body) do
    Map.get(body, "jsonrpc") == "2.0" and Map.has_key?(body, "id") and
      Map.has_key?(body, "error") and is_map(Map.get(body, "error"))
  end

  defp json_rpc_error_response?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> json_rpc_error_response?(decoded)
      {:error, _reason} -> false
    end
  end

  defp json_rpc_error_response?(_body), do: false

  defp deliver_json_error_response(state, status, body) do
    decoded_body = decode_json_body(body)

    if json_rpc_error_response?(decoded_body) do
      deliver_json_response(state, decoded_body)
    else
      {:error, {:http_error, status, decoded_body}}
    end
  end

  defp decode_json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp deliver_sse_error_response(state, status, body) when is_binary(body) do
    parser = SSE.new_parser(max_event_bytes: state.security_policy.max_sse_event_bytes)

    case SSE.feed(parser, body) do
      {:error, reason} -> {:error, reason}
      {:ok, events, _parser} -> deliver_sse_http_error_events(state, status, body, events)
    end
  end

  defp deliver_sse_http_error_events(state, status, body, events) do
    error = Enum.find_value(events, &decode_sse_error/1)
    if error, do: deliver_json_response(state, error), else: {:error, {:http_error, status, body}}
  end

  defp decode_sse_error(event) do
    with data when is_binary(data) <- Map.get(event, :data),
         {:ok, decoded} <- Jason.decode(data),
         true <- json_rpc_error_response?(decoded),
         do: decoded,
         else: (_invalid -> nil)
  end

  defp build_headers(state, message, opts) do
    with {:ok, custom_headers} <-
           custom_routing_headers(message, Keyword.get(opts, :routing_headers, [])) do
      {:ok,
       [
         {"content-type", "application/json"},
         {"accept", "application/json, text/event-stream"},
         {"mcp-protocol-version", request_protocol_version(message, state.protocol_version)}
       ] ++
         session_headers(state) ++
         routing_headers(message) ++ custom_headers ++ state.extra_headers}
    end
  end

  defp request_protocol_version(message, fallback) do
    get_in(message, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"]) ||
      get_in(message, ["params", "protocolVersion"]) || fallback
  end

  defp routing_headers(%{"method" => method} = message) do
    [{"mcp-method", method}] ++ routing_name_header(method, Map.get(message, "params"))
  end

  defp routing_headers(_message), do: []

  defp routing_name_header(method, params) when is_map(params) do
    target =
      case method do
        "tools/call" -> Map.get(params, "name")
        "prompts/get" -> Map.get(params, "name")
        "resources/read" -> Map.get(params, "uri")
        _method -> nil
      end

    if target, do: [{"mcp-name", encode_header_value(target)}], else: []
  end

  defp routing_name_header(_method, _params), do: []

  defp custom_routing_headers(%{"params" => %{"arguments" => arguments}}, descriptors)
       when is_map(arguments) do
    Enum.reduce_while(descriptors, {:ok, []}, fn descriptor, {:ok, headers} ->
      name = "mcp-param-#{String.downcase(descriptor.header)}"

      case ToolRouting.argument_value(arguments, descriptor) do
        :missing ->
          {:cont, {:ok, headers}}

        {:ok, value} ->
          {:cont, {:ok, headers ++ [{name, encode_header_value(value)}]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_routing_argument, name, reason}}}
      end
    end)
  end

  defp custom_routing_headers(_message, _descriptors), do: {:ok, []}

  defp encode_header_value(value) when is_binary(value) do
    if plain_header_value?(value) do
      value
    else
      "=?base64?#{Base.encode64(value)}?="
    end
  end

  defp plain_header_value?(value) do
    safe_bytes? =
      value
      |> :binary.bin_to_list()
      |> Enum.all?(&(&1 == 0x09 or &1 in 0x20..0x7E))

    safe_bytes? and value == String.trim(value) and not sentinel_shaped?(value)
  end

  defp sentinel_shaped?(value) do
    String.starts_with?(value, "=?base64?") and String.ends_with?(value, "?=")
  end

  defp reserved_extra_header(headers) do
    Enum.find_value(headers, fn
      {name, _value} when is_binary(name) -> if reserved_header?(name), do: name
      _header -> nil
    end)
  end

  defp reserved_header?(name) do
    normalized = String.downcase(name)

    normalized in [
      "content-type",
      "accept",
      "mcp-protocol-version",
      "mcp-method",
      "mcp-name",
      "mcp-session-id"
    ] or String.starts_with?(normalized, "mcp-param-")
  end

  defp get_content_type(headers) do
    get_header(headers, "content-type") || ""
  end

  defp get_header(headers, name) do
    # Req returns headers as a map of %{name => [values]}
    case headers do
      %{^name => [value | _]} -> value
      _ -> nil
    end
  end

  defp parse_sse_body(state, body) when is_binary(body) do
    # Parse complete SSE body (from a non-streaming response)
    parser = SSE.new_parser(max_event_bytes: state.security_policy.max_sse_event_bytes)

    case SSE.feed(parser, body) do
      {:error, reason} ->
        {:error, reason}

      {:ok, events, _parser} ->
        deliver_sse_events(events, state)
    end
  end

  defp deliver_sse_events(events, state) do
    Enum.reduce_while(events, {:ok, state}, fn event, result ->
      case Map.get(event, :data) do
        data when data in [nil, ""] -> {:cont, result}
        data -> deliver_sse_event(state.owner, data, result)
      end
    end)
  end

  defp deliver_sse_event(owner, data, result) do
    case deliver_decoded(owner, data) do
      :ok -> {:cont, result}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp deliver_json_response(state, body) when is_map(body) do
    send(state.owner, {:mcp_message, body})
    {:ok, state}
  end

  defp deliver_json_response(state, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        send(state.owner, {:mcp_message, decoded})
        {:ok, state}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  defp deliver_decoded(owner, data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} ->
        send(owner, {:mcp_message, decoded})
        :ok

      {:error, reason} ->
        {:error, {:invalid_sse_json, reason}}
    end
  end

  defp do_close(state, session_cleanup \\ :asynchronous) do
    if state.legacy_sse_task do
      Process.demonitor(state.legacy_sse_ref, [:flush])
      # A long-polling Req task can take seconds to unwind through a supervised
      # shutdown. The listener owns no state, so an untrappable exit makes
      # close deterministic while the supervisor reaps the child.
      Process.exit(state.legacy_sse_task, :kill)
    end

    Enum.each(state.post_tasks, fn {_ref, operation} ->
      Process.demonitor(operation.caller_ref, [:flush])
      _ = Task.Supervisor.terminate_child(state.task_supervisor, operation.task_pid)
    end)

    Enum.each(state.subscriptions, fn {_id, subscription} ->
      Process.demonitor(subscription.monitor_ref, [:flush])
      _ = Task.Supervisor.terminate_child(state.task_supervisor, subscription.task)
    end)

    case session_cleanup do
      :synchronous -> terminate_legacy_session_if_present(state)
      :asynchronous -> asynchronously_terminate_legacy_session(state)
    end
  end

  defp transport_close_failure(state, kind, reason, stacktrace) do
    Logger.error("MCP HTTP transport close failed " <> Exception.format(kind, reason, stacktrace))

    {:stop, :normal, {:error, {:close_failed, {kind, reason}}},
     %{state | session_id: nil, legacy_sse_task: nil, legacy_sse_ref: nil}}
  end

  defp bind_response_session(
         transport,
         %{"method" => "initialize"} = message,
         fallback_version,
         headers
       ) do
    case get_header(headers, "mcp-session-id") do
      nil ->
        :ok

      session_id ->
        protocol_version = request_protocol_version(message, fallback_version)
        GenServer.call(transport, {:bind_session, session_id, protocol_version})
    end
  end

  defp bind_response_session(_transport, _message, _fallback_version, _headers), do: :ok

  defp session_headers(%{session_id: nil}), do: []
  defp session_headers(%{session_id: session_id}), do: [{"mcp-session-id", session_id}]

  defp terminate_legacy_session(state) do
    headers = [
      {"mcp-protocol-version", state.protocol_version},
      {"mcp-session-id", state.session_id}
    ]

    case ResponseReader.request(
           [method: :delete, url: state.endpoint, headers: headers],
           state.security_policy
         ) do
      {:ok, %Req.Response{status: status}, _body} when status in [200, 202, 204, 404] ->
        :ok

      {:ok, %Req.Response{status: status}, _body} ->
        {:error, {:session_delete_failed, status}}

      {:error, reason} ->
        {:error, {:session_delete_failed, reason}}
    end
  end

  defp terminate_legacy_session_if_present(%{session_id: nil}), do: :ok
  defp terminate_legacy_session_if_present(state), do: terminate_legacy_session(state)

  defp asynchronously_terminate_legacy_session(%{session_id: nil}), do: :ok

  defp asynchronously_terminate_legacy_session(state) do
    cleanup = %{
      endpoint: state.endpoint,
      protocol_version: state.protocol_version,
      session_id: state.session_id,
      security_policy: state.security_policy
    }

    {:ok, _pid} =
      Task.start(fn ->
        case terminate_legacy_session(cleanup) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("MCP session DELETE failed: #{inspect(reason)}")
        end
      end)

    :ok
  end

  defp clear_legacy_session(state) do
    if state.legacy_sse_task do
      Process.demonitor(state.legacy_sse_ref, [:flush])
      Process.exit(state.legacy_sse_task, :kill)
    end

    %{state | session_id: nil, legacy_sse_task: nil, legacy_sse_ref: nil}
  end

  defp start_legacy_sse_listener(%{legacy_sse_task: task} = state) when is_pid(task), do: state

  defp start_legacy_sse_listener(state) do
    transport = self()

    {:ok, task} =
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        reason =
          legacy_sse_loop(
            state.owner,
            state.endpoint,
            state.session_id,
            state.protocol_version,
            state.extra_headers,
            state.legacy_sse_retry_limit,
            state.legacy_sse_retry_backoff,
            state.legacy_sse_retry_max_backoff,
            state.security_policy
          )

        send(transport, {:legacy_sse_stopped, self(), reason})
      end)

    %{state | legacy_sse_task: task, legacy_sse_ref: Process.monitor(task)}
  end

  # Retry state is passed explicitly to keep the long-lived listener isolated.
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp legacy_sse_loop(
         owner,
         url,
         session_id,
         protocol_version,
         extra_headers,
         retries_left,
         backoff,
         max_backoff,
         security_policy
       ) do
    headers =
      [
        {"accept", "text/event-stream"},
        {"mcp-session-id", session_id},
        {"mcp-protocol-version", protocol_version}
      ] ++ extra_headers

    result =
      case ResponseReader.request(
             [method: :get, url: url, headers: headers, stream: true],
             security_policy
           ) do
        {:stream, %Req.Response{status: 200} = response} ->
          consume_legacy_sse_stream(
            owner,
            response,
            SSE.new_parser(max_event_bytes: security_policy.max_sse_event_bytes),
            security_policy.receive_timeout
          )

        {:stream, %Req.Response{status: 404} = response} ->
          _ = Req.cancel_async_response(response)
          :session_expired

        {:stream, %Req.Response{status: status} = response} ->
          _ = Req.cancel_async_response(response)
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      :session_expired ->
        :session_expired

      :eof ->
        retry_legacy_eof(
          owner,
          url,
          session_id,
          protocol_version,
          extra_headers,
          retries_left,
          backoff,
          max_backoff,
          security_policy
        )

      _result when retries_left <= 0 ->
        {:retry_exhausted, result}

      _result ->
        wait_legacy_retry(backoff)

        legacy_sse_loop(
          owner,
          url,
          session_id,
          protocol_version,
          extra_headers,
          retries_left - 1,
          min(backoff * 2, max_backoff),
          max_backoff,
          security_policy
        )
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp retry_legacy_eof(
         _owner,
         _url,
         _session_id,
         _protocol_version,
         _headers,
         0,
         _backoff,
         _max,
         _policy
       ),
       do: {:retry_exhausted, :eof}

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp retry_legacy_eof(
         owner,
         url,
         session_id,
         protocol_version,
         headers,
         retries,
         backoff,
         max,
         policy
       ) do
    wait_legacy_retry(backoff)

    legacy_sse_loop(
      owner,
      url,
      session_id,
      protocol_version,
      headers,
      retries - 1,
      min(backoff * 2, max),
      max,
      policy
    )
  end

  defp consume_legacy_sse_stream(owner, response, parser, receive_timeout) do
    receive do
      message ->
        case Req.parse_message(response, message) do
          {:ok, chunks} ->
            consume_legacy_sse_chunks(owner, response, parser, chunks, receive_timeout)

          {:error, reason} ->
            _ = Req.cancel_async_response(response)
            {:error, reason}

          :unknown ->
            consume_legacy_sse_stream(owner, response, parser, receive_timeout)
        end
    after
      receive_timeout ->
        _ = Req.cancel_async_response(response)
        {:error, :receive_timeout}
    end
  end

  defp consume_legacy_sse_chunks(owner, response, parser, chunks, receive_timeout) do
    Enum.reduce_while(chunks, {:continue, parser}, fn
      {:data, data}, {:continue, current_parser} ->
        consume_legacy_sse_data(owner, response, current_parser, data)

      :done, {:continue, current_parser} ->
        {:halt, {:done, current_parser}}

      {:trailers, _trailers}, accumulator ->
        {:cont, accumulator}
    end)
    |> case do
      {:continue, next_parser} ->
        consume_legacy_sse_stream(owner, response, next_parser, receive_timeout)

      {:done, _parser} ->
        :eof

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consume_legacy_sse_data(owner, response, parser, data) do
    with {:ok, events, next_parser} <- SSE.feed(parser, data),
         :ok <- deliver_legacy_sse_events(owner, events) do
      {:cont, {:continue, next_parser}}
    else
      {:error, reason} ->
        _ = Req.cancel_async_response(response)
        {:halt, {:error, reason}}
    end
  end

  defp deliver_legacy_sse_events(owner, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case Map.get(event, :data) do
        data when is_binary(data) and data != "" ->
          reduce_legacy_sse_event(owner, data)

        _empty ->
          {:cont, :ok}
      end
    end)
  end

  defp reduce_legacy_sse_event(owner, data) do
    case deliver_decoded(owner, data) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp wait_legacy_retry(delay) do
    receive do
      :stop -> :ok
    after
      delay -> :ok
    end
  end

  defp start_subscription_task(state, id, message, headers) do
    transport = self()
    url = state.endpoint

    {:ok, task} =
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        run_subscription_stream(transport, id, url, message, headers, state.security_policy)
      end)

    monitor_ref = Process.monitor(task)
    subscription = %{task: task, monitor_ref: monitor_ref}
    subscriptions = Map.put(state.subscriptions, id, subscription)
    {:reply, :ok, %{state | subscriptions: subscriptions}}
  end

  defp run_subscription_stream(transport, id, url, message, headers, security_policy) do
    result =
      case ResponseReader.request(
             [
               method: :post,
               url: url,
               body: Jason.encode!(message),
               headers: headers,
               stream: true
             ],
             security_policy
           ) do
        {:stream, %Req.Response{status: 200} = response} ->
          if String.contains?(get_content_type(response.headers), "text/event-stream") do
            consume_subscription_stream(
              transport,
              id,
              response,
              SSE.new_parser(max_event_bytes: security_policy.max_sse_event_bytes),
              security_policy.receive_timeout
            )
          else
            _ = Req.cancel_async_response(response)
            {:error, {:unexpected_content_type, get_content_type(response.headers)}}
          end

        {:stream, %Req.Response{status: status} = response} ->
          case ResponseReader.consume(
                 response,
                 security_policy.max_response_bytes,
                 security_policy.receive_timeout
               ) do
            {:ok, body} -> {:error, {:http_error, status, body}}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end

    send(transport, {:subscription_stream_closed, id, result})
  rescue
    exception ->
      send(
        transport,
        {:subscription_stream_closed, id, {:error, {:raised, exception, __STACKTRACE__}}}
      )
  end

  defp consume_subscription_stream(transport, id, response, parser, receive_timeout) do
    receive do
      {:cancel_subscription_stream, requested_id} when requested_id in [id, :all] ->
        _ = Req.cancel_async_response(response)
        {:error, :cancelled}

      message ->
        case Req.parse_message(response, message) do
          {:ok, chunks} ->
            consume_subscription_chunks(
              transport,
              id,
              response,
              parser,
              chunks,
              receive_timeout
            )

          {:error, reason} ->
            _ = Req.cancel_async_response(response)
            {:error, reason}

          :unknown ->
            consume_subscription_stream(transport, id, response, parser, receive_timeout)
        end
    after
      receive_timeout ->
        _ = Req.cancel_async_response(response)
        {:error, :receive_timeout}
    end
  end

  defp consume_subscription_chunks(transport, id, response, parser, chunks, receive_timeout) do
    Enum.reduce_while(chunks, {:continue, parser}, fn
      {:data, data}, {:continue, current_parser} ->
        consume_subscription_data(transport, id, response, current_parser, data)

      :done, {:continue, current_parser} ->
        {:halt, {:done, current_parser}}

      {:trailers, _trailers}, accumulator ->
        {:cont, accumulator}
    end)
    |> case do
      {:continue, next_parser} ->
        consume_subscription_stream(transport, id, response, next_parser, receive_timeout)

      {:done, _parser} ->
        :eof

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consume_subscription_data(transport, id, response, parser, data) do
    with {:ok, events, next_parser} <- SSE.feed(parser, data),
         :ok <- deliver_subscription_events(transport, id, events) do
      {:cont, {:continue, next_parser}}
    else
      {:error, reason} ->
        _ = Req.cancel_async_response(response)
        {:halt, {:error, reason}}
    end
  end

  defp deliver_subscription_events(transport, id, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case Map.get(event, :data) do
        nil ->
          {:cont, :ok}

        "" ->
          {:cont, :ok}

        data ->
          deliver_subscription_event(transport, id, data)
      end
    end)
  end

  defp deliver_subscription_event(transport, id, data) do
    case Jason.decode(data) do
      {:ok, decoded} ->
        delivery_ref = make_ref()
        send(transport, {:subscription_stream_message, id, self(), delivery_ref, decoded})

        receive do
          {:subscription_delivery_ack, ^delivery_ref} ->
            {:cont, :ok}

          {:cancel_subscription_stream, requested_id} when requested_id in [id, :all] ->
            {:halt, {:error, :cancelled}}
        after
          5_000 -> {:halt, {:error, {:subscription_delivery_timeout, id}}}
        end

      {:error, reason} ->
        {:halt, {:error, {:invalid_sse_json, reason}}}
    end
  end

  defp subscription_by_monitor(subscriptions, ref, task) do
    Enum.find(subscriptions, fn {_id, subscription} ->
      subscription.monitor_ref == ref and subscription.task == task
    end)
  end

  defp post_task_by_caller_ref(post_tasks, ref, caller) do
    Enum.find_value(post_tasks, fn {_task_ref, operation} ->
      if operation.caller_ref == ref and elem(operation.from, 0) == caller, do: operation
    end)
  end
end
