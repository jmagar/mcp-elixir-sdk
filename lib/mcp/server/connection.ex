defmodule MCP.Server.Connection do
  @moduledoc """
  Dual-era connection driver for **owner-based** transports (stdio and
  in-process/`BridgeTransport`).

  The first protocol request selects either the 2026 stateless dispatcher or
  the 2025 initialize/session state machine. Modes cannot be mixed. Both paths
  use one immutable handler configuration and per-request `ToolContext`.

  ## Identity (PO Comment B — stdio/in-process)

  There is no `conn`; the trust boundary is the pipe/process. A launch-static
  `:identity` option (part of `:handler_opts`, or given directly) is resolved
  **once at launch** and stamped on every per-request context. All other
  constraints (MC-1, MC-3, MC-4, MC-6) apply identically.

  ## Options

    * `:transport` — `{module, opts}` transport spec (started here, owner = self)
    * `:handler` — `{module, opts}` handler spec (module implements
      `MCP.Server.Handler`)
    * `:server_info` / `:instructions` / `:cache_defaults` — forwarded to
      `MCP.Server.Config.build/2`
    * `:identity` — launch-static caller identity for every request (optional)
  """

  use GenServer

  require Logger

  alias MCP.Protocol
  alias MCP.Protocol.Capabilities.{ClientCapabilities, ElicitationCapabilities}
  alias MCP.Protocol.Error
  alias MCP.Protocol.Messages.{Notification, Request, Response}
  alias MCP.Protocol.Messages.Subscriptions.{ListenParams, ListenResult}
  alias MCP.Protocol.Methods
  alias MCP.Protocol.Types.SubscriptionFilter

  alias MCP.Server.{
    Config,
    Dispatch,
    LegacyDispatch,
    SubscriptionRegistry,
    SubscriptionWorker,
    ToolContext
  }

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"
  @legacy_mrtr_max_inputs 32
  @legacy_mrtr_concurrency 8

  defstruct [
    :transport_module,
    :transport_pid,
    :config,
    :identity,
    :subscription_supervisor,
    :subscription_registry,
    :subscription_endpoint,
    :protocol_mode,
    :legacy_status,
    :legacy_client_info,
    :legacy_client_capabilities,
    :legacy_log_level,
    :next_id,
    :pending_client_requests,
    :request_timeout,
    :task_supervisor,
    :max_concurrent_handlers,
    :handler_timeout,
    subscription_queue_limit: 256,
    handler_tasks: %{},
    subscriptions: %{}
  ]

  # --- Public API ---

  @doc "Starts a protocol-era connection and its transport."
  def start_link(opts) do
    {gen_opts, server_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, server_opts, gen_opts)
  end

  @doc "Returns the transport pid (testing convenience)."
  def transport(server), do: GenServer.call(server, :get_transport)

  @doc "Closes the connection and its transport."
  def close(server) do
    GenServer.call(server, :close)
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, reason -> {:error, {:close_failed, reason}}
  end

  @doc "Gracefully closes one active subscription and emits its final result."
  @spec close_subscription(GenServer.server(), String.t() | integer()) ::
          :ok | {:error, :not_found}
  def close_subscription(server, request_id) do
    GenServer.call(server, {:close_subscription, request_id})
  end

  @doc "Requests sampling from a negotiated MCP 2025-11-25 client."
  def request_sampling(server, params, timeout \\ 60_000),
    do: request_client(server, Methods.sampling_create_message(), params, timeout)

  @doc "Requests roots from a negotiated MCP 2025-11-25 client."
  def request_roots(server, timeout \\ 30_000),
    do: request_client(server, Methods.roots_list(), %{}, timeout)

  @doc "Requests elicitation from a negotiated MCP 2025-11-25 client."
  def request_elicitation(server, params, timeout \\ 60_000),
    do: request_client(server, Methods.elicitation_create(), params, timeout)

  defp request_client(server, method, params, timeout) do
    if valid_timeout?(timeout) do
      GenServer.call(server, {:request_client, method, params, timeout}, :infinity)
    else
      {:error, {:invalid_timeout, timeout}}
    end
  end

  @doc "Notifies a legacy client that the tool list changed."
  def notify_tools_changed(server),
    do: GenServer.call(server, {:legacy_notify, Methods.tools_list_changed(), nil})

  @doc "Notifies a legacy client that the resource list changed."
  def notify_resources_changed(server),
    do: GenServer.call(server, {:legacy_notify, Methods.resources_list_changed(), nil})

  @doc "Notifies a legacy client that one resource changed."
  def notify_resource_updated(server, uri),
    do: GenServer.call(server, {:legacy_notify, Methods.resources_updated(), %{"uri" => uri}})

  @doc "Notifies a legacy client that the prompt list changed."
  def notify_prompts_changed(server),
    do: GenServer.call(server, {:legacy_notify, Methods.prompts_list_changed(), nil})

  @doc "Sends a legacy logging notification when allowed by the negotiated level."
  def log(server, level, data, logger_name \\ nil),
    do: GenServer.call(server, {:legacy_log, level, data, logger_name})

  @doc "Sends a legacy progress notification."
  def send_progress(server, progress_token, progress, total \\ nil) do
    params = %{"progressToken" => progress_token, "progress" => progress}
    params = if is_nil(total), do: params, else: Map.put(params, "total", total)
    GenServer.call(server, {:legacy_notify, Methods.progress(), params})
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    {transport_spec, opts} = Keyword.pop!(opts, :transport)
    {handler_spec, opts} = Keyword.pop!(opts, :handler)
    {handler_module, handler_opts} = handler_spec

    identity = Keyword.get(opts, :identity, Keyword.get(handler_opts, :identity))

    subscriptions_enabled =
      not is_nil(Keyword.get(opts, :subscription_supervisor)) and
        not is_nil(Keyword.get(opts, :subscription_registry))

    config_opts =
      opts
      |> Keyword.put(:handler_opts, handler_opts)
      |> Keyword.put(:subscriptions_enabled, subscriptions_enabled)

    with :ok <- validate_subscription_options(opts),
         :ok <- validate_request_timeout(Keyword.get(opts, :request_timeout, 30_000)),
         :ok <- validate_handler_limits(opts),
         {:ok, task_supervisor} <- Task.Supervisor.start_link(),
         {:ok, config} <- Config.build(handler_module, config_opts),
         {:ok, module, pid} <- start_transport(transport_spec) do
      {:ok,
       %__MODULE__{
         transport_module: module,
         transport_pid: pid,
         config: config,
         identity: identity,
         subscription_supervisor: Keyword.get(opts, :subscription_supervisor),
         subscription_registry: Keyword.get(opts, :subscription_registry),
         subscription_endpoint: Keyword.get(opts, :subscription_endpoint, self()),
         subscription_queue_limit: Keyword.get(opts, :subscription_queue_limit, 256),
         protocol_mode: :undetermined,
         legacy_status: :waiting,
         legacy_log_level: "info",
         next_id: 1,
         pending_client_requests: %{},
         request_timeout: Keyword.get(opts, :request_timeout, 30_000),
         task_supervisor: task_supervisor,
         max_concurrent_handlers: Keyword.get(opts, :max_concurrent_handlers, 32),
         handler_timeout: Keyword.get(opts, :handler_timeout, 30_000),
         handler_tasks: %{},
         subscriptions: %{}
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:get_transport, _from, state), do: {:reply, state.transport_pid, state}

  def handle_call(:close, _from, state) do
    state = state |> fail_pending_client_requests(:closed) |> close_all_subscriptions()

    case close_transport(state) do
      :ok -> {:stop, :normal, :ok, state}
      {:error, reason} -> server_close_failure(state, :exit, reason, [])
    end
  rescue
    exception -> server_close_failure(state, :error, exception, __STACKTRACE__)
  catch
    kind, reason -> server_close_failure(state, kind, reason, __STACKTRACE__)
  end

  def handle_call({:close_subscription, request_id}, _from, state) do
    case graceful_close_subscription(state, request_id) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, :not_found} -> {:reply, {:error, :not_found}, state}
      {:error, reason, state} -> {:stop, reason, {:error, reason}, state}
    end
  end

  def handle_call(
        {:legacy_notify, method, params},
        _from,
        %{protocol_mode: :legacy, legacy_status: :ready} = state
      ) do
    {:reply, send_legacy_notification(state, method, params), state}
  end

  def handle_call({:legacy_notify, _method, _params}, _from, state),
    do: {:reply, {:error, :legacy_client_not_ready}, state}

  def handle_call(
        {:legacy_log, level, data, logger_name},
        _from,
        %{protocol_mode: :legacy, legacy_status: :ready} = state
      ) do
    cond do
      not valid_log_level?(level) ->
        {:reply, {:error, :invalid_log_level}, state}

      log_level_allowed?(level, state.legacy_log_level) ->
        params = %{"level" => level, "data" => data}
        params = if is_nil(logger_name), do: params, else: Map.put(params, "logger", logger_name)
        {:reply, send_legacy_notification(state, Methods.logging_message(), params), state}

      true ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:legacy_log, _level, _data, _logger_name}, _from, state),
    do: {:reply, {:error, :legacy_client_not_ready}, state}

  def handle_call(
        {:request_client, method, params, timeout},
        from,
        %{protocol_mode: :legacy, legacy_status: :ready} = state
      ) do
    case require_client_capability(method, params, state.legacy_client_capabilities) do
      :ok ->
        id = state.next_id
        message = Request.new(id, method, params) |> Jason.encode!() |> Jason.decode!()

        case state.transport_module.send_message(state.transport_pid, message) do
          :ok ->
            timeout_ref = Process.send_after(self(), {:client_request_timeout, id}, timeout)
            monitor_ref = Process.monitor(elem(from, 0))
            pending = Map.put(state.pending_client_requests, id, {from, timeout_ref, monitor_ref})
            {:noreply, %{state | next_id: id + 1, pending_client_requests: pending}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:request_client, _method, _params, _timeout}, _from, state),
    do: {:reply, {:error, :legacy_client_not_ready}, state}

  defp server_close_failure(state, kind, reason, stacktrace) do
    Logger.error("MCP server close failed " <> Exception.format(kind, reason, stacktrace))
    {:stop, :normal, {:error, {:close_failed, {kind, reason}}}, state}
  end

  defp close_transport(%{transport_pid: nil}), do: :ok

  defp close_transport(state) do
    case state.transport_module.close(state.transport_pid) do
      :ok -> :ok
      {:error, reason} -> {:error, {:transport_close_failed, reason}}
      other -> {:error, {:invalid_transport_close_result, other}}
    end
  end

  @impl GenServer
  def handle_info({:mcp_message, message}, state) do
    case Protocol.decode_message(message) do
      {:error, %Error{} = error} ->
        Logger.warning("MCP.Server.Connection: failed to decode message: #{inspect(error)}")

        id = error_response_id(message)

        send_protocol_error(state, id, error)

      decoded ->
        handle_decoded_message(decoded, state)
    end
  end

  def handle_info({:mcp_transport_closed, reason}, state) do
    {:stop, :normal, fail_pending_client_requests(state, {:transport_closed, reason})}
  end

  def handle_info({:client_request_timeout, id}, state) do
    case Map.pop(state.pending_client_requests, id) do
      {{from, _timeout_ref, monitor_ref}, pending} ->
        Process.demonitor(monitor_ref, [:flush])
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending_client_requests: pending}}

      {nil, _pending} ->
        {:noreply, state}
    end
  end

  def handle_info({:legacy_inputs_resolved, request, responses, request_state}, state) do
    params =
      (request.params || %{})
      |> Map.put("inputResponses", responses)
      |> maybe_put_request_state(request_state)

    dispatch_legacy(%{request | params: params}, state)
  end

  def handle_info({:legacy_inputs_failed, id, reason}, state),
    do:
      send_protocol_error(
        state,
        id,
        Error.internal_error(%{"reason" => legacy_input_failure(reason)})
      )

  def handle_info({:handler_result, ref, result}, state) do
    case pop_handler_task(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {%{kind: {:stateless, _message}}, state} ->
        finish_stateless_handler(result, state)

      {%{kind: {:legacy, request}}, state} ->
        finish_legacy_handler(result, request, state)

      {%{kind: {:subscription, request, requested}}, state} ->
        finish_subscription_authorization(result, request, requested, state)
    end
  end

  def handle_info({:handler_timeout, ref}, state) do
    case pop_handler_task(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {%{pid: pid, kind: kind}, state} ->
        Process.exit(pid, :kill)
        request_id = handler_request_id(kind)

        if is_nil(request_id) do
          {:noreply, state}
        else
          send_protocol_error(state, request_id, Error.internal_error("handler timeout"))
        end
    end
  end

  def handle_info({:mcp_subscription_ready, id, worker}, state) do
    deliver_subscription_message(id, worker, state)
  end

  def handle_info({:DOWN, ref, :process, worker, reason}, state) do
    case handler_by_monitor(state.handler_tasks, ref, worker) do
      {handler_ref, %{kind: kind}} ->
        {_task, state} = pop_handler_task(state, handler_ref)
        request_id = handler_request_id(kind)

        if reason == :normal or is_nil(request_id) do
          {:noreply, state}
        else
          send_protocol_error(state, request_id, Error.internal_error("handler failed"))
        end

      nil ->
        handle_non_handler_down(ref, worker, reason, state)
    end
  end

  def handle_info(msg, state) do
    Logger.debug("MCP.Server.Connection: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Internals ---

  defp handle_non_handler_down(ref, worker, reason, state) do
    case subscription_by_monitor(state.subscriptions, ref, worker) do
      nil ->
        {:noreply, remove_pending_client_request(state, ref)}

      {id, _subscription} when reason == :normal ->
        {:noreply, remove_subscription(state, id)}

      {id, _subscription} ->
        state = remove_subscription(state, id)

        send_protocol_error(
          state,
          id,
          Error.internal_error(%{"reason" => subscription_exit_reason(reason)})
        )
    end
  end

  defp handle_decoded_message({:ok, %Request{method: "initialize"} = request}, state),
    do: initialize_legacy(request, state)

  defp handle_decoded_message(
         {:ok, %Request{method: "subscriptions/listen"} = request},
         %{protocol_mode: :legacy} = state
       ),
       do: dispatch_legacy(request, state)

  defp handle_decoded_message(
         {:ok, %Request{method: "subscriptions/listen"} = request},
         state
       ),
       do: open_subscription(request, state)

  defp handle_decoded_message({:ok, %Request{} = request}, state),
    do: dispatch_versioned(request, state)

  defp handle_decoded_message(
         {:ok, %Notification{method: "notifications/initialized"}},
         state
       ),
       do: initialize_legacy_notification(state)

  defp handle_decoded_message(
         {:ok, %Notification{method: "notifications/cancelled"} = notification},
         %{protocol_mode: :stateless} = state
       ),
       do: cancel_subscription(notification, state)

  defp handle_decoded_message(
         {:ok, %Notification{}},
         %{protocol_mode: mode} = state
       )
       when mode in [:undetermined, :legacy],
       do: {:noreply, state}

  defp handle_decoded_message({:ok, %Notification{} = notification}, state),
    do: dispatch(notification, nil, state)

  defp handle_decoded_message({:ok, %Response{} = response}, state),
    do: handle_client_response(response, state)

  defp handle_client_response(%Response{id: id} = response, state) do
    case Map.pop(state.pending_client_requests, id) do
      {{from, timeout_ref, monitor_ref}, pending} ->
        Process.cancel_timer(timeout_ref)
        Process.demonitor(monitor_ref, [:flush])
        reply = if response.error, do: {:error, response.error}, else: {:ok, response.result}
        GenServer.reply(from, reply)
        {:noreply, %{state | pending_client_requests: pending}}

      {nil, _pending} ->
        Logger.warning("MCP.Server.Connection: response for unknown request id=#{inspect(id)}")
        {:noreply, state}
    end
  end

  defp initialize_legacy(%Request{id: id} = request, %{protocol_mode: mode} = state)
       when mode in [:undetermined, :legacy] do
    if state.legacy_status == :waiting do
      case LegacyDispatch.initialize(request, state.config) do
        {:ok, response, initialize} ->
          finish_legacy_initialization(state, response, initialize)

        {:error, response} ->
          finish_protocol_send(state, response)
      end
    else
      send_protocol_error(state, id, Error.invalid_request("Already initialized"))
    end
  end

  defp initialize_legacy(%Request{id: id}, state),
    do: send_protocol_error(state, id, Error.invalid_request("Protocol mode already selected"))

  defp finish_legacy_initialization(state, response, initialize) do
    case state.transport_module.send_message(state.transport_pid, response) do
      :ok ->
        {:noreply,
         %{
           state
           | protocol_mode: :legacy,
             legacy_status: :initialized,
             legacy_client_info: initialize.client_info,
             legacy_client_capabilities: initialize.capabilities
         }}

      {:error, reason} ->
        {:stop, {:transport_send_failed, reason}, state}
    end
  end

  defp initialize_legacy_notification(
         %{protocol_mode: :legacy, legacy_status: :initialized} = state
       ),
       do: {:noreply, %{state | legacy_status: :ready}}

  defp initialize_legacy_notification(%{protocol_mode: :legacy} = state), do: {:noreply, state}

  defp initialize_legacy_notification(state),
    do: dispatch(%Notification{method: "notifications/initialized", params: nil}, nil, state)

  defp dispatch_versioned(%Request{id: id} = request, %{protocol_mode: :legacy} = state) do
    if stateless_request?(request) do
      send_protocol_error(state, id, Error.invalid_request("Protocol mode already selected"))
    else
      dispatch_legacy(request, state)
    end
  end

  defp dispatch_versioned(request, state) do
    case Dispatch.validate_request(request.params, state.config) do
      :ok -> dispatch(request, request.id, %{state | protocol_mode: :stateless})
      {:error, _error} -> dispatch(request, request.id, state)
    end
  end

  defp dispatch_legacy(%Request{id: id}, %{legacy_status: status} = state)
       when status != :ready,
       do: send_protocol_error(state, id, Error.invalid_request("Server not initialized"))

  defp dispatch_legacy(%Request{} = request, state) do
    context = %ToolContext{
      request_id: request.id,
      meta: request_meta(request.params),
      identity: state.identity,
      reply_sink: reply_sink(state, request.id)
    }

    start_handler_task(state, {:legacy, request}, fn ->
      LegacyDispatch.dispatch(request, context, state.config)
    end)
  end

  defp finish_legacy_handler(result, request, state) do
    case result do
      {:reply, response} ->
        case state.transport_module.send_message(state.transport_pid, response) do
          :ok -> {:noreply, update_legacy_request_state(state, request, response)}
          {:error, reason} -> {:stop, {:transport_send_failed, reason}, state}
        end

      {:input_required, requests, request_state} ->
        case resolve_legacy_inputs(
               state.task_supervisor,
               request,
               requests,
               request_state,
               state.request_timeout
             ) do
          {:ok, _pid} ->
            {:noreply, state}

          {:error, {:too_many_input_requests, _count, _limit} = reason} ->
            send_protocol_error(
              state,
              request.id,
              Error.invalid_params(%{
                "reason" => "too_many_input_requests",
                "count" => elem(reason, 1),
                "limit" => elem(reason, 2)
              })
            )

          {:error, reason} ->
            send_protocol_error(
              state,
              request.id,
              Error.internal_error(%{
                "message" => "Unable to start legacy input request",
                "reason" => legacy_input_failure(reason)
              })
            )
        end
    end
  end

  defp resolve_legacy_inputs(task_supervisor, request, requests, request_state, timeout) do
    server = self()

    if map_size(requests) <= @legacy_mrtr_max_inputs do
      Task.Supervisor.start_child(task_supervisor, fn ->
        task_supervisor
        |> collect_legacy_inputs(server, requests, timeout)
        |> report_legacy_inputs(server, request, request_state)
      end)
    else
      {:error, {:too_many_input_requests, map_size(requests), @legacy_mrtr_max_inputs}}
    end
  end

  defp collect_legacy_inputs(task_supervisor, server, requests, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    task_supervisor
    |> Task.Supervisor.async_stream_nolink(
      requests,
      fn {key, input_request} -> resolve_legacy_input(server, key, input_request, deadline) end,
      max_concurrency: @legacy_mrtr_concurrency,
      ordered: false,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {:ok, key, response}}, {:ok, responses} ->
        {:cont, {:ok, Map.put(responses, key, response)}}

      {:ok, {:error, reason}}, _responses ->
        {:halt, {:error, reason}}

      {:exit, reason}, _responses ->
        {:halt, {:error, reason}}
    end)
  end

  defp resolve_legacy_input(server, key, input_request, deadline) when is_map(input_request) do
    method = Map.get(input_request, "method")
    params = Map.get(input_request, "params", %{})
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      case request_client(server, method, params, remaining) do
        {:ok, response} -> {:ok, key, response}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :timeout}
    end
  end

  defp resolve_legacy_input(_server, _key, _input_request, _timeout),
    do: {:error, :input_request_must_be_an_object}

  defp request_meta(params) when is_map(params), do: Map.get(params, "_meta")
  defp request_meta(_params), do: nil

  defp report_legacy_inputs({:ok, responses}, server, request, request_state),
    do: send(server, {:legacy_inputs_resolved, request, responses, request_state})

  defp report_legacy_inputs({:error, reason}, server, request, _request_state),
    do: send(server, {:legacy_inputs_failed, request.id, reason})

  defp maybe_put_request_state(params, nil), do: Map.delete(params, "requestState")

  defp maybe_put_request_state(params, request_state),
    do: Map.put(params, "requestState", request_state)

  defp stateless_request?(%Request{
         params: %{
           "_meta" => %{
             "io.modelcontextprotocol/protocolVersion" => protocol_version
           }
         }
       }),
       do: protocol_version == Dispatch.protocol_version()

  defp stateless_request?(%Request{}), do: false

  defp fail_pending_client_requests(state, reason) do
    Enum.each(state.pending_client_requests, fn {_id, {from, timeout_ref, monitor_ref}} ->
      Process.cancel_timer(timeout_ref)
      Process.demonitor(monitor_ref, [:flush])
      GenServer.reply(from, {:error, reason})
    end)

    %{state | pending_client_requests: %{}}
  end

  defp remove_pending_client_request(state, monitor_ref) do
    case Enum.find(state.pending_client_requests, fn {_id, {_from, _timer, ref}} ->
           ref == monitor_ref
         end) do
      {id, {_from, timeout_ref, ^monitor_ref}} ->
        Process.cancel_timer(timeout_ref)
        %{state | pending_client_requests: Map.delete(state.pending_client_requests, id)}

      nil ->
        state
    end
  end

  defp update_legacy_request_state(
         state,
         %Request{method: "logging/setLevel", params: params},
         %{"result" => _result}
       ),
       do: %{state | legacy_log_level: Map.get(params || %{}, "level", "info")}

  defp update_legacy_request_state(state, _request, _response), do: state

  defp send_legacy_notification(state, method, params) do
    message = Notification.new(method, params) |> Jason.encode!() |> Jason.decode!()
    state.transport_module.send_message(state.transport_pid, message)
  end

  defp log_level_allowed?(level, minimum) do
    levels = ~w(debug info notice warning error critical alert emergency)
    level_index = Enum.find_index(levels, &(&1 == level))
    minimum_index = Enum.find_index(levels, &(&1 == minimum))
    is_integer(level_index) and is_integer(minimum_index) and level_index >= minimum_index
  end

  defp valid_log_level?(level),
    do: level in ~w(debug info notice warning error critical alert emergency)

  defp valid_timeout?(timeout), do: is_integer(timeout) and timeout > 0

  defp validate_request_timeout(timeout) do
    if valid_timeout?(timeout),
      do: :ok,
      else: {:error, {:invalid_request_timeout, timeout}}
  end

  defp validate_handler_limits(opts) do
    max_concurrent = Keyword.get(opts, :max_concurrent_handlers, 32)
    timeout = Keyword.get(opts, :handler_timeout, 30_000)

    if is_integer(max_concurrent) and max_concurrent > 0 and is_integer(timeout) and timeout > 0,
      do: :ok,
      else: {:error, :invalid_handler_limits}
  end

  defp require_client_capability(
         method,
         params,
         %ClientCapabilities{} = capabilities
       ) do
    cond do
      method == Methods.sampling_create_message() and is_nil(capabilities.sampling) ->
        {:error, Error.missing_required_client_capability("sampling")}

      method == Methods.roots_list() and is_nil(capabilities.roots) ->
        {:error, Error.missing_required_client_capability("roots")}

      method == Methods.elicitation_create() ->
        require_elicitation_capability(params, capabilities.elicitation)

      method in [
        Methods.sampling_create_message(),
        Methods.roots_list(),
        Methods.elicitation_create()
      ] ->
        :ok

      true ->
        {:error, Error.missing_required_client_capability(method)}
    end
  end

  defp require_client_capability(method, _params, _capabilities),
    do: {:error, Error.missing_required_client_capability(method)}

  defp require_elicitation_capability(
         %{"mode" => "url"},
         %ElicitationCapabilities{url: url}
       )
       when not is_nil(url),
       do: :ok

  defp require_elicitation_capability(
         params,
         %ElicitationCapabilities{form: form}
       )
       when not is_nil(form) do
    if is_map(params) and Map.get(params, "mode") in [nil, "form"],
      do: :ok,
      else: {:error, Error.missing_required_client_capability("elicitation")}
  end

  defp require_elicitation_capability(
         params,
         %ElicitationCapabilities{form: nil, url: nil}
       )
       when is_map(params) do
    if Map.get(params, "mode") in [nil, "form"],
      do: :ok,
      else: {:error, Error.missing_required_client_capability("elicitation")}
  end

  defp require_elicitation_capability(_params, _capabilities),
    do: {:error, Error.missing_required_client_capability("elicitation")}

  defp dispatch(message, request_id, state) do
    ctx = %ToolContext{
      request_id: request_id,
      meta: extract_meta(message),
      identity: state.identity,
      reply_sink: reply_sink(state, request_id)
    }

    start_handler_task(state, {:stateless, message}, fn ->
      Dispatch.dispatch(message, ctx, state.config)
    end)
  end

  defp finish_stateless_handler(result, state) do
    case result do
      {:reply, response} ->
        case state.transport_module.send_message(state.transport_pid, response) do
          :ok -> {:noreply, state}
          {:error, reason} -> {:stop, {:transport_send_failed, reason}, state}
        end

      :noreply ->
        {:noreply, state}
    end
  end

  defp open_subscription(%Request{id: id, params: params}, state) do
    with :ok <- Dispatch.validate_request(params, state.config),
         :ok <- subscription_configuration(state),
         {:ok, requested} <- parse_subscription_filter(params) do
      begin_subscription_authorization(state, id, params, requested)
    else
      {:error, %Error{} = error} ->
        send_protocol_error(state, id, error)

      {:error, reason} ->
        Logger.error("MCP subscription authorization failed: #{inspect(reason)}")
        send_protocol_error(state, id, Error.internal_error("subscription authorization failed"))
    end
  end

  defp begin_subscription_authorization(state, id, params, requested) do
    if duplicate_subscription?(state, id) do
      send_protocol_error(state, id, Error.invalid_request(:duplicate_request_id))
    else
      state = %{state | protocol_mode: :stateless}

      start_handler_task(
        state,
        {:subscription, %Request{id: id, params: params}, requested},
        fn -> authorize_subscription(id, params, requested, state) end
      )
    end
  end

  defp duplicate_subscription?(state, id) do
    Map.has_key?(state.subscriptions, id) or
      Enum.any?(state.handler_tasks, fn {_ref, task} ->
        match?({:subscription, %Request{id: ^id}, _requested}, task.kind)
      end)
  end

  defp finish_subscription_authorization(
         {:ok, %SubscriptionFilter{} = honored},
         %Request{id: id},
         requested,
         state
       ) do
    case start_subscription_worker(id, requested, honored, state) do
      {:ok, worker} ->
        monitor_ref = Process.monitor(worker)
        subscription = %{worker: worker, monitor_ref: monitor_ref}

        {:noreply,
         %{
           state
           | subscriptions: Map.put(state.subscriptions, id, subscription)
         }}

      {:error, reason} ->
        Logger.error("MCP subscription worker failed to start: #{inspect(reason)}")
        send_protocol_error(state, id, Error.internal_error("subscription unavailable"))
    end
  end

  defp finish_subscription_authorization({:error, %Error{} = error}, %Request{id: id}, _, state),
    do: send_protocol_error(state, id, error)

  defp finish_subscription_authorization({:error, reason}, %Request{id: id}, _, state) do
    Logger.error("MCP subscription authorization failed: #{inspect(reason)}")
    send_protocol_error(state, id, Error.internal_error("subscription authorization failed"))
  end

  defp subscription_configuration(%{
         subscription_supervisor: supervisor,
         subscription_registry: registry,
         subscription_queue_limit: queue_limit
       }) do
    cond do
      is_nil(supervisor) or is_nil(registry) ->
        {:error, Error.method_not_found("subscriptions/listen")}

      not (is_integer(queue_limit) and queue_limit > 0) ->
        {:error, {:invalid_subscription_queue_limit, queue_limit}}

      true ->
        :ok
    end
  end

  defp validate_subscription_options(opts) do
    supervisor = Keyword.get(opts, :subscription_supervisor)
    registry = Keyword.get(opts, :subscription_registry)
    queue_limit = Keyword.get(opts, :subscription_queue_limit, 256)

    cond do
      not (is_integer(queue_limit) and queue_limit > 0) ->
        {:error, {:invalid_subscription_queue_limit, queue_limit}}

      is_nil(supervisor) and is_nil(registry) ->
        :ok

      is_nil(supervisor) or is_nil(registry) ->
        {:error, :incomplete_subscription_configuration}

      true ->
        with {:ok, _registry_name} <- SubscriptionRegistry.name(registry) do
          validate_subscription_supervisor(supervisor)
        end
    end
  end

  defp validate_subscription_supervisor(supervisor) do
    case GenServer.whereis(supervisor) do
      pid when is_pid(pid) -> :ok
      nil -> {:error, :invalid_subscription_supervisor}
    end
  end

  defp parse_subscription_filter(params) do
    {:ok, ListenParams.from_map(params).notifications}
  rescue
    error in [ArgumentError, KeyError] -> {:error, Error.invalid_params(Exception.message(error))}
  end

  defp authorize_subscription(id, params, requested, state) do
    module = state.config.handler_module

    if function_exported?(module, :handle_listen_subscriptions, 3) do
      context = %ToolContext{
        request_id: id,
        meta: Map.get(params || %{}, "_meta"),
        identity: state.identity,
        reply_sink: reply_sink(state, id)
      }

      case module.handle_listen_subscriptions(requested, context, state.config.handler_state) do
        {:ok, %SubscriptionFilter{} = honored} -> {:ok, honored}
        {:error, code, message} -> {:error, %Error{code: code, message: message}}
        other -> {:error, {:invalid_subscription_callback_result, other}}
      end
    else
      {:error, Error.method_not_found("subscriptions/listen")}
    end
  rescue
    exception -> {:error, {:subscription_callback_raised, exception, __STACKTRACE__}}
  end

  defp start_subscription_worker(id, requested, honored, state) do
    SubscriptionWorker.start(
      state.subscription_supervisor,
      state.subscription_registry,
      state.subscription_endpoint,
      id,
      self(),
      requested,
      honored,
      queue_limit: state.subscription_queue_limit,
      notify_owner: true
    )
  end

  defp cancel_subscription(%Notification{params: params} = notification, state)
       when is_nil(params) or is_map(params) do
    case Map.get(params || %{}, "requestId") do
      id when is_binary(id) or is_integer(id) ->
        case graceful_close_subscription(state, id) do
          {:ok, state} -> {:noreply, state}
          {:error, :not_found} -> dispatch(notification, nil, state)
          {:error, reason, state} -> {:stop, reason, state}
        end

      _invalid ->
        dispatch(notification, nil, state)
    end
  end

  defp cancel_subscription(%Notification{}, state), do: {:noreply, state}

  defp deliver_subscription_message(id, worker, state) do
    case Map.get(state.subscriptions, id) do
      %{worker: ^worker} ->
        case SubscriptionWorker.next(worker, 0) do
          {:ok, message} ->
            send_subscription_message(state, id, message)

          {:error, :timeout} ->
            {:noreply, state}

          {:error, reason} ->
            state = remove_subscription(state, id)

            send_protocol_error(
              state,
              id,
              Error.internal_error(%{"reason" => subscription_delivery_error(reason)})
            )
        end

      _missing ->
        {:noreply, state}
    end
  end

  defp send_subscription_message(state, id, message) do
    case state.transport_module.send_message(state.transport_pid, message) do
      :ok -> {:noreply, state}
      {:error, _reason} -> stop_subscription_abruptly(state, id)
    end
  end

  defp graceful_close_subscription(state, id) do
    case Map.fetch(state.subscriptions, id) do
      {:ok, subscription} ->
        state = remove_subscription(state, id)
        GenServer.stop(subscription.worker, :normal)

        result = %ListenResult{meta: %{@subscription_id_key => id}}
        response = Response.success(id, ListenResult.to_map(result)) |> encode()

        case send_transport_message(state, response) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason, state}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp stop_subscription_abruptly(state, id) do
    case Map.fetch(state.subscriptions, id) do
      {:ok, subscription} ->
        state = remove_subscription(state, id)
        GenServer.stop(subscription.worker, :normal)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  defp remove_subscription(state, id) do
    case Map.pop(state.subscriptions, id) do
      {nil, _subscriptions} ->
        state

      {subscription, subscriptions} ->
        Process.demonitor(subscription.monitor_ref, [:flush])
        %{state | subscriptions: subscriptions}
    end
  end

  defp subscription_by_monitor(subscriptions, ref, worker) do
    Enum.find(subscriptions, fn {_id, subscription} ->
      subscription.monitor_ref == ref and subscription.worker == worker
    end)
  end

  defp subscription_exit_reason(:queue_overflow), do: "subscription_queue_overflow"
  defp subscription_exit_reason(_reason), do: "subscription_closed_abruptly"

  defp subscription_delivery_error(:closed), do: "subscription_closed_abruptly"
  defp subscription_delivery_error({:noproc, _call}), do: "subscription_closed_abruptly"
  defp subscription_delivery_error(_reason), do: "subscription_delivery_failed"

  defp legacy_input_failure(:timeout), do: "legacy_input_timeout"
  defp legacy_input_failure(_reason), do: "legacy_input_failed"

  defp close_all_subscriptions(state) do
    Enum.reduce(Map.keys(state.subscriptions), state, fn id, acc ->
      case graceful_close_subscription(acc, id) do
        {:ok, next_state} -> next_state
        {:error, :not_found} -> acc
        {:error, reason, _next_state} -> exit(reason)
      end
    end)
  end

  defp send_protocol_error(state, id, %Error{} = error) do
    response = Response.error(id, error) |> encode()
    finish_protocol_send(state, response)
  end

  defp finish_protocol_send(state, response) do
    case send_transport_message(state, response) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp send_transport_message(state, message) do
    case state.transport_module.send_message(state.transport_pid, message) do
      :ok -> :ok
      {:error, reason} -> {:error, {:transport_send_failed, reason}}
      other -> {:error, {:invalid_transport_send_result, other}}
    end
  end

  # Per-request notification emitter: writes straight to the transport (no
  # GenServer round-trip — dispatch runs in this process synchronously).
  defp reply_sink(state, request_id) do
    transport_module = state.transport_module
    transport_pid = state.transport_pid

    fn method, params ->
      message = Notification.new(method, params) |> encode()

      if state.protocol_mode == :legacy and
           function_exported?(transport_module, :send_request_notification, 3) do
        transport_module.send_request_notification(transport_pid, request_id, message)
      else
        transport_module.send_message(transport_pid, message)
      end

      :ok
    end
  end

  defp encode(struct), do: Jason.decode!(Jason.encode!(struct))

  defp valid_error_response_id?(id), do: is_integer(id) or is_binary(id)

  @dialyzer {:nowarn_function, error_response_id: 1}
  defp error_response_id(message) when is_map(message) do
    id = Map.get(message, "id")
    if valid_error_response_id?(id), do: id, else: nil
  end

  defp error_response_id(_message), do: nil

  defp start_handler_task(state, kind, fun) do
    cond do
      duplicate_handler_request?(state, kind) ->
        reject_duplicate_handler_request(state, kind)

      map_size(state.handler_tasks) >= state.max_concurrent_handlers ->
        reject_handler_at_capacity(state, kind)

      true ->
        do_start_handler_task(state, kind, fun)
    end
  end

  defp duplicate_handler_request?(state, kind) do
    case handler_request_id(kind) do
      nil ->
        false

      request_id ->
        Map.has_key?(state.subscriptions, request_id) or
          Enum.any?(state.handler_tasks, fn {_ref, task} ->
            handler_request_id(task.kind) == request_id
          end)
    end
  end

  defp reject_duplicate_handler_request(state, kind) do
    send_protocol_error(
      state,
      handler_request_id(kind),
      Error.invalid_request(:duplicate_request_id)
    )
  end

  defp do_start_handler_task(state, kind, fun) do
    owner = self()
    ref = make_ref()

    result =
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        result = fun.()
        send(owner, {:handler_result, ref, result})
      end)

    finish_start_handler_task(result, state, kind, ref, owner)
  end

  defp finish_start_handler_task({:ok, pid}, state, kind, ref, owner) do
    monitor_ref = Process.monitor(pid)
    timer_ref = Process.send_after(owner, {:handler_timeout, ref}, state.handler_timeout)
    task = %{pid: pid, monitor_ref: monitor_ref, timer_ref: timer_ref, kind: kind}
    {:noreply, put_in(state.handler_tasks[ref], task)}
  end

  defp finish_start_handler_task({:error, reason}, state, kind, _ref, _owner) do
    Logger.error("MCP handler task failed to start: #{inspect(reason)}")
    reject_unavailable_handler(state, kind)
  end

  defp reject_handler_at_capacity(state, kind) do
    case handler_request_id(kind) do
      nil -> {:noreply, state}
      id -> send_protocol_error(state, id, Error.internal_error("handler capacity reached"))
    end
  end

  defp reject_unavailable_handler(state, kind) do
    case handler_request_id(kind) do
      nil -> {:noreply, state}
      id -> send_protocol_error(state, id, Error.internal_error("handler unavailable"))
    end
  end

  defp handler_request_id({:subscription, %Request{id: id}, _requested}), do: id
  defp handler_request_id({_era, %Request{id: id}}), do: id
  defp handler_request_id(_kind), do: nil

  defp pop_handler_task(state, ref) do
    case Map.pop(state.handler_tasks, ref) do
      {nil, _tasks} ->
        {nil, state}

      {task, tasks} ->
        Process.cancel_timer(task.timer_ref)
        Process.demonitor(task.monitor_ref, [:flush])
        {task, %{state | handler_tasks: tasks}}
    end
  end

  defp handler_by_monitor(tasks, monitor_ref, pid) do
    Enum.find(tasks, fn {_ref, task} ->
      task.monitor_ref == monitor_ref and task.pid == pid
    end)
  end

  defp extract_meta(%Request{params: params}) when is_map(params), do: Map.get(params, "_meta")
  defp extract_meta(_), do: nil

  defp start_transport({module, opts}) do
    case module.start_link([{:owner, self()} | opts]) do
      {:ok, pid} -> {:ok, module, pid}
      {:error, reason} -> {:error, reason}
    end
  end
end
