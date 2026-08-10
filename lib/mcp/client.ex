defmodule MCP.Client do
  @moduledoc """
  MCP client for the 2026-07-28 and 2025-11-25 protocol eras.

  A GenServer that manages a connection to an MCP server via a pluggable
  transport. It prefers stateless `server/discover` and makes one bounded
  fallback to the legacy initialize handshake when required. Stateless calls
  stamp per-request `_meta`; legacy calls use negotiated session state.

  ## Usage

      {:ok, client} = MCP.Client.start_link(
        transport: {MCP.Transport.StreamableHTTP.Client, url: "http://localhost:8080"},
        client_info: %{name: "my_app", version: "1.0.0"}
      )

      {:ok, info}  = MCP.Client.connect(client)          # server/discover probe
      {:ok, tools} = MCP.Client.list_tools(client)
      {:ok, out}   = MCP.Client.call_tool(client, "my_tool", %{"arg" => "val"})

  ## Multi Round-Trip Requests (SEP-2322)

  If any request result comes back with `resultType: "input_required"`, the
  client fulfils the requested inputs via the optional `:on_input_required`
  callback and **retries** the original request carrying `inputResponses` and
  the exact `requestState` when one was supplied. Only the final `complete`
  result is returned to the caller. Without a resolver, the
  `InputRequiredResult` is returned as-is.

  ## Options

    * `:transport` — `{module, opts}` transport spec (started here, owner = self)
    * `:client_info` — `%Implementation{}` or `%{name:, version:}`
    * `:client_capabilities` — `%ClientCapabilities{}` or a string-keyed map
      (advertised in `_meta`)
    * `:protocol_version` — advertised version (default: the stateless core's)
    * `:notification_handler` — pid or `(method, params -> any)` for server
      notifications
    * `:on_input_required` — `(input_requests -> input_responses)` MRTR resolver
    * `:request_timeout` — default request timeout in ms (default: 30_000)
    * `:tool_schema_limit` — maximum cached tool schemas (default: 1,024)
  """

  use GenServer

  require Logger

  alias MCP.Client.{SubscriptionHandle, SubscriptionWorker}
  alias MCP.Protocol

  alias MCP.Protocol.Capabilities.{
    ClientCapabilities,
    ElicitationCapabilities,
    RootCapabilities,
    SamplingCapabilities
  }

  alias MCP.Protocol.Error
  alias MCP.Protocol.Messages.{Discover, Initialize, MRTR, Notification, Request, Response}
  alias MCP.Protocol.Messages.Subscriptions.{AcknowledgedParams, ListenParams, ListenResult}
  alias MCP.Protocol.Methods
  alias MCP.Protocol.Revision
  alias MCP.Protocol.ToolRouting
  alias MCP.Protocol.Types.{Implementation, SubscriptionFilter}

  @default_request_timeout 30_000
  @max_tool_refresh_pages 32
  @default_subscription_queue_limit 256
  @default_notification_concurrency 32
  @default_server_request_concurrency 32
  @default_server_request_timeout 30_000
  @protocol_version "2026-07-28"
  @subscription_ack_method "notifications/subscriptions/acknowledged"

  # Client state is intentionally explicit so lifecycle ownership remains inspectable.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :transport_module,
    :transport_pid,
    :server_capabilities,
    :server_info,
    :client_info,
    :client_capabilities,
    :protocol_version,
    :legacy_adapter,
    :status,
    :notification_handler,
    :on_input_required,
    :request_handlers,
    :legacy_ready,
    :connect_waiters,
    :connect_result,
    :tool_schema_index,
    :tool_schema_order,
    :tool_schema_limit,
    :pending_requests,
    :next_id,
    :request_timeout,
    :task_supervisor,
    :notification_supervisor,
    :server_request_supervisor,
    :server_request_timeout,
    :subscription_supervisor,
    :subscription_queue_limit,
    transport_tasks: %{},
    callback_tasks: %{},
    server_request_tasks: %{},
    subscription_open_tasks: %{},
    subscriptions: %{}
  ]

  # --- Public API ---

  @doc "Starts the client GenServer and its transport."
  def start_link(opts) do
    {gen_opts, client_opts} = Keyword.split(opts, [:name])

    case validate_start_options(client_opts) do
      :ok -> GenServer.start_link(__MODULE__, client_opts, gen_opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Probes the server via `server/discover` (the stateless replacement for the
  removed `initialize` handshake).

  Returns `{:ok, %{server_info:, server_capabilities:, protocol_version:,
  instructions:}}`.
  """
  def connect(client, timeout \\ 60_000) do
    with :ok <- validate_timeout(timeout) do
      GenServer.call(client, {:connect, timeout}, :infinity)
    end
  end

  @doc "Lists available tools. Options: `:cursor`, `:timeout`."
  def list_tools(client, opts \\ []) do
    with :ok <- validate_call_options(opts) do
      {timeout, opts} = Keyword.pop(opts, :timeout)
      GenServer.call(client, {:list_tools, opts, timeout}, :infinity)
    end
  end

  @doc """
  Calls a tool. Transparently completes MRTR round-trips when a resolver is set.

  Options: `:timeout` and `:input_schema`. The latter supplies the selected
  tool's input schema explicitly for routing-header derivation.
  """
  def call_tool(client, name, arguments \\ %{}, opts \\ []) do
    with :ok <- validate_call_options(opts) do
      timeout = Keyword.get(opts, :timeout)
      input_schema = Keyword.get(opts, :input_schema)
      meta = Keyword.get(opts, :meta)

      GenServer.call(
        client,
        {:call_tool, name, arguments, input_schema, meta, timeout},
        :infinity
      )
    end
  end

  @doc "Lists available resources. Options: `:cursor`, `:timeout`."
  def list_resources(client, opts \\ []) do
    with :ok <- validate_call_options(opts) do
      {timeout, opts} = Keyword.pop(opts, :timeout)
      GenServer.call(client, {:list_resources, opts, timeout}, :infinity)
    end
  end

  @doc "Reads a resource by URI."
  def read_resource(client, uri, opts \\ []) do
    with :ok <- validate_call_options(opts) do
      timeout = Keyword.get(opts, :timeout)
      GenServer.call(client, {:read_resource, uri, Keyword.get(opts, :meta), timeout}, :infinity)
    end
  end

  @doc "Lists resource templates. Options: `:cursor`, `:timeout`."
  def list_resource_templates(client, opts \\ []) do
    with :ok <- validate_call_options(opts) do
      {timeout, opts} = Keyword.pop(opts, :timeout)
      GenServer.call(client, {:list_resource_templates, opts, timeout}, :infinity)
    end
  end

  @doc "Lists available prompts. Options: `:cursor`, `:timeout`."
  def list_prompts(client, opts \\ []) do
    with :ok <- validate_call_options(opts) do
      {timeout, opts} = Keyword.pop(opts, :timeout)
      GenServer.call(client, {:list_prompts, opts, timeout}, :infinity)
    end
  end

  @doc "Gets a specific prompt by name with optional arguments."
  def get_prompt(client, name, arguments \\ %{}, opts \\ []) do
    with :ok <- validate_call_options(opts) do
      timeout = Keyword.get(opts, :timeout)

      GenServer.call(
        client,
        {:get_prompt, name, arguments, Keyword.get(opts, :meta), timeout},
        :infinity
      )
    end
  end

  @doc "Requests a completion."
  def complete(client, ref, argument, opts \\ []) do
    with :ok <- validate_call_options(opts) do
      timeout = Keyword.get(opts, :timeout)

      GenServer.call(
        client,
        {:complete, ref, argument, Keyword.get(opts, :meta), timeout},
        :infinity
      )
    end
  end

  @doc "Sends the legacy `ping` request."
  def ping(client, opts \\ []) do
    with :ok <- validate_call_options(opts) do
      GenServer.call(
        client,
        {:legacy_call, Methods.ping(), %{}, Keyword.get(opts, :timeout)},
        :infinity
      )
    end
  end

  @doc "Subscribes to updates for a resource under MCP 2025-11-25."
  def subscribe_resource(client, uri, opts \\ []) do
    with :ok <- validate_call_options(opts) do
      params = put_meta(%{"uri" => uri}, Keyword.get(opts, :meta))

      GenServer.call(
        client,
        {:legacy_call, Methods.resources_subscribe(), params, Keyword.get(opts, :timeout)},
        :infinity
      )
    end
  end

  @doc "Unsubscribes from resource updates under MCP 2025-11-25."
  def unsubscribe_resource(client, uri, opts \\ []) do
    with :ok <- validate_call_options(opts) do
      params = put_meta(%{"uri" => uri}, Keyword.get(opts, :meta))

      GenServer.call(
        client,
        {:legacy_call, Methods.resources_unsubscribe(), params, Keyword.get(opts, :timeout)},
        :infinity
      )
    end
  end

  @doc "Notifies a legacy server that the client's roots changed."
  def notify_roots_changed(client), do: GenServer.call(client, :notify_roots_changed)

  @doc """
  Opens a long-lived `subscriptions/listen` request.

  The client must be started with a consumer-owned `:subscription_supervisor`.
  Options: `:queue_limit` and `:timeout` for opening the local worker.
  """
  @spec listen_subscriptions(GenServer.server(), SubscriptionFilter.t(), keyword()) ::
          {:ok, SubscriptionHandle.t()} | {:error, term()}
  def listen_subscriptions(client, filter, opts \\ [])

  def listen_subscriptions(client, %SubscriptionFilter{} = filter, opts) when is_list(opts) do
    with :ok <- validate_call_options(opts) do
      {timeout, opts} = Keyword.pop(opts, :timeout, @default_request_timeout)

      GenServer.call(
        client,
        {:listen_subscriptions, filter, Keyword.put(opts, :open_timeout, timeout)},
        :infinity
      )
    end
  end

  def listen_subscriptions(_client, filter, _opts),
    do: {:error, {:invalid_subscription_filter, filter}}

  @doc "Closes the client and its transport."
  def close(client) do
    GenServer.call(client, :close)
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, reason -> {:error, {:close_failed, reason}}
  end

  @doc "Cancels a pending request by ID (sends `notifications/cancelled`)."
  def cancel(client, request_id, reason \\ nil) do
    GenServer.cast(client, {:cancel_request, request_id, reason})
  end

  @doc "Returns the transport pid (testing convenience)."
  def transport(client), do: GenServer.call(client, :get_transport)

  @doc "Returns the current client status (`:ready` or `:closed`)."
  def status(client), do: GenServer.call(client, :get_status)

  @doc "Returns the discovered server capabilities (after `connect/1`)."
  def server_capabilities(client), do: GenServer.call(client, :get_server_capabilities)

  @doc "Returns the discovered server info (after `connect/1`)."
  def server_info(client), do: GenServer.call(client, :get_server_info)

  # --- Pagination helpers ---

  @doc "Lists all tools, paginating automatically."
  def list_all_tools(client, opts \\ []), do: list_all(client, :list_tools, :tools, opts)

  @doc "Lists all resources, paginating automatically."
  def list_all_resources(client, opts \\ []),
    do: list_all(client, :list_resources, :resources, opts)

  @doc "Lists all resource templates, paginating automatically."
  def list_all_resource_templates(client, opts \\ []),
    do: list_all(client, :list_resource_templates, :resource_templates, opts)

  @doc "Lists all prompts, paginating automatically."
  def list_all_prompts(client, opts \\ []), do: list_all(client, :list_prompts, :prompts, opts)

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    tool_schema_limit = Keyword.get(opts, :tool_schema_limit, 1_024)

    if is_integer(tool_schema_limit) and tool_schema_limit >= 0 do
      init_with_schema_limit(opts, tool_schema_limit)
    else
      {:stop, {:invalid_tool_schema_limit, tool_schema_limit}}
    end
  end

  defp init_with_schema_limit(opts, tool_schema_limit) do
    {transport_spec, opts} = Keyword.pop!(opts, :transport)

    {:ok, task_supervisor} = Task.Supervisor.start_link()

    notification_concurrency =
      Keyword.get(opts, :notification_concurrency, @default_notification_concurrency)

    {:ok, notification_supervisor} =
      Task.Supervisor.start_link(max_children: notification_concurrency)

    server_request_concurrency =
      Keyword.get(opts, :server_request_concurrency, @default_server_request_concurrency)

    {:ok, server_request_supervisor} =
      Task.Supervisor.start_link(max_children: server_request_concurrency)

    {automatic_capabilities, automatic_handlers} = legacy_callback_config(opts)

    client_capabilities =
      case Keyword.fetch(opts, :client_capabilities) do
        {:ok, capabilities} -> normalize_client_capabilities(capabilities)
        :error -> automatic_capabilities
      end

    request_handlers = Map.merge(automatic_handlers, Keyword.get(opts, :request_handlers, %{}))

    state = %__MODULE__{
      client_info: build_client_info(Keyword.get(opts, :client_info, default_info())),
      client_capabilities: client_capabilities,
      protocol_version: Keyword.get(opts, :protocol_version, @protocol_version),
      legacy_adapter: legacy_adapter(Keyword.get(opts, :protocol_version, @protocol_version)),
      status: :ready,
      notification_handler: Keyword.get(opts, :notification_handler),
      on_input_required: Keyword.get(opts, :on_input_required),
      request_handlers: request_handlers,
      legacy_ready: false,
      connect_waiters: nil,
      tool_schema_index: %{},
      tool_schema_order: [],
      tool_schema_limit: tool_schema_limit,
      pending_requests: %{},
      next_id: 1,
      request_timeout: Keyword.get(opts, :request_timeout, @default_request_timeout),
      task_supervisor: task_supervisor,
      notification_supervisor: notification_supervisor,
      server_request_supervisor: server_request_supervisor,
      server_request_timeout:
        Keyword.get(opts, :server_request_timeout, @default_server_request_timeout),
      subscription_supervisor: Keyword.get(opts, :subscription_supervisor),
      subscription_queue_limit:
        Keyword.get(opts, :subscription_queue_limit, @default_subscription_queue_limit),
      subscriptions: %{}
    }

    transport_spec = put_transport_protocol_version(transport_spec, state.protocol_version)

    case start_transport(transport_spec) do
      {:ok, module, pid} -> {:ok, %{state | transport_module: module, transport_pid: pid}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:connect, _timeout}, _from, %{status: :closed} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:connect, timeout}, from, state) do
    cond do
      state.connect_result && (not legacy_protocol?(state) or state.legacy_ready) ->
        {:reply, {:ok, state.connect_result}, state}

      is_list(state.connect_waiters) ->
        waiter_ref = make_ref()
        timeout_ref = Process.send_after(self(), {:connect_waiter_timeout, waiter_ref}, timeout)

        waiter = %{
          from: from,
          waiter_ref: waiter_ref,
          timeout_ref: timeout_ref,
          deadline: System.monotonic_time(:millisecond) + timeout
        }

        {:noreply, %{state | connect_waiters: [waiter | state.connect_waiters]}}

      legacy_protocol?(state) ->
        state = %{state | connect_waiters: []}
        send_initialize(state, from, timeout)

      true ->
        state = %{state | connect_waiters: []}
        send_rpc(state, from, Methods.discover(), %{}, {:discover, false}, [], timeout)
    end
  end

  # Introspection + close work in any state (including :closed) and must precede
  # the closed-guard below, which only rejects RPC operations.
  def handle_call(:close, _from, state), do: do_close(state)
  def handle_call(:get_transport, _from, state), do: {:reply, state.transport_pid, state}
  def handle_call(:get_status, _from, state), do: {:reply, state.status, state}

  def handle_call(:get_server_capabilities, _from, state),
    do: {:reply, state.server_capabilities, state}

  def handle_call(:get_server_info, _from, state), do: {:reply, state.server_info, state}

  def handle_call(_request, _from, %{status: :closed} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call(_request, _from, %{legacy_adapter: adapter, legacy_ready: false} = state)
      when not is_nil(adapter),
      do: {:reply, {:error, :not_ready}, state}

  def handle_call({:list_tools, opts, timeout}, from, state),
    do: send_rpc(state, from, Methods.tools_list(), cursor_params(opts), :tools_list, [], timeout)

  def handle_call({:call_tool, name, arguments, input_schema, meta, timeout}, from, state) do
    case selected_descriptors(state, name, input_schema) do
      {:ok, descriptors, state} ->
        send_rpc(
          state,
          from,
          Methods.tools_call(),
          name_args(name, arguments) |> put_meta(meta),
          {:tool_call, name, arguments, false, descriptors},
          [routing_headers: descriptors],
          timeout
        )

      {:error, reason} ->
        {:reply, {:error, {:invalid_input_schema, reason}}, state}
    end
  end

  def handle_call({:list_resources, opts, timeout}, from, state),
    do: send_rpc(state, from, Methods.resources_list(), cursor_params(opts), :call, [], timeout)

  def handle_call({:read_resource, uri, meta, timeout}, from, state),
    do:
      send_rpc(
        state,
        from,
        Methods.resources_read(),
        put_meta(%{"uri" => uri}, meta),
        :call,
        [],
        timeout
      )

  def handle_call({:list_resource_templates, opts, timeout}, from, state),
    do:
      send_rpc(
        state,
        from,
        Methods.resources_templates_list(),
        cursor_params(opts),
        :call,
        [],
        timeout
      )

  def handle_call({:list_prompts, opts, timeout}, from, state),
    do: send_rpc(state, from, Methods.prompts_list(), cursor_params(opts), :call, [], timeout)

  def handle_call({:get_prompt, name, arguments, meta, timeout}, from, state),
    do:
      send_rpc(
        state,
        from,
        Methods.prompts_get(),
        name_args(name, arguments) |> put_meta(meta),
        :call,
        [],
        timeout
      )

  def handle_call({:complete, ref, argument, meta, timeout}, from, state),
    do:
      send_rpc(
        state,
        from,
        Methods.completion_complete(),
        put_meta(%{"ref" => ref, "argument" => argument}, meta),
        :call,
        [],
        timeout
      )

  def handle_call({:legacy_call, method, params, timeout}, from, state) do
    if legacy_protocol?(state) and state.legacy_ready do
      send_rpc(state, from, method, params, :call, [], timeout)
    else
      legacy_not_ready_reply(state)
    end
  end

  def handle_call(:notify_roots_changed, _from, state) do
    cond do
      not legacy_protocol?(state) ->
        {:reply, {:error, :legacy_protocol_required}, state}

      not state.legacy_ready ->
        {:reply, {:error, :not_ready}, state}

      true ->
        {:reply, send_notification(state, Methods.roots_list_changed(), nil), state}
    end
  end

  def handle_call(
        {:listen_subscriptions, _filter, _opts},
        _from,
        %{legacy_adapter: adapter} = state
      )
      when not is_nil(adapter),
      do: {:reply, {:error, :stateless_protocol_required}, state}

  def handle_call({:listen_subscriptions, filter, opts}, from, state) do
    open_subscription(state, from, filter, opts)
  end

  @impl GenServer
  def handle_cast({:cancel_request, request_id, reason}, %{status: :ready} = state) do
    params = %{"requestId" => request_id}
    params = if reason, do: Map.put(params, "reason", reason), else: params
    send_notification(state, Methods.cancelled(), params)
    {:noreply, state}
  end

  def handle_cast({:cancel_request, _id, _reason}, state), do: {:noreply, state}

  # --- Incoming messages ---

  @impl GenServer
  def handle_info({:mcp_message, message}, state) do
    case Protocol.decode_message(message) do
      {:ok, %Response{} = response} ->
        handle_response(response, state)

      {:ok, %Notification{} = notification} ->
        handle_notification(notification, state)

      {:ok, %Request{} = request} ->
        handle_server_request(request, state)

      {:error, error} ->
        Logger.warning("MCP Client: failed to decode message: #{inspect(error)}")
        {:noreply, state}
    end
  end

  def handle_info(
        {:mcp_subscription_message, transport, stream, delivery_ref, message},
        %{transport_pid: transport} = state
      ) do
    result =
      case Protocol.decode_message(message) do
        {:ok, %Response{} = response} ->
          handle_response(response, state)

        {:ok, %Notification{} = notification} ->
          handle_notification(notification, state)

        {:ok, _other} ->
          {:noreply, state}

        {:error, error} ->
          Logger.warning("MCP Client: invalid subscription message: #{inspect(error)}")
          {:noreply, state}
      end

    send(stream, {:subscription_delivery_ack, delivery_ref})
    result
  end

  def handle_info({:mcp_transport_closed, reason}, state) do
    state = fail_all_operations(state, {:transport_closed, reason})

    Enum.each(state.subscriptions, fn {_id, subscription} ->
      Process.demonitor(subscription.monitor_ref, [:flush])
      SubscriptionWorker.fail(subscription.worker, {:transport_closed, reason})
    end)

    {:noreply, %{state | status: :closed, subscriptions: %{}}}
  end

  def handle_info({:mcp_legacy_sse_failed, reason}, state) do
    Logger.warning("MCP legacy SSE listener unavailable: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:mcp_subscription_transport_closed, id, reason}, state) do
    case Map.pop(state.subscriptions, id) do
      {nil, _subscriptions} ->
        {:noreply, state}

      {subscription, subscriptions} ->
        Process.demonitor(subscription.monitor_ref, [:flush])
        SubscriptionWorker.fail(subscription.worker, {:transport_closed, reason})
        {:noreply, %{state | subscriptions: subscriptions}}
    end
  end

  def handle_info({:DOWN, ref, :process, worker, reason}, state)
      when not is_map_key(state.transport_tasks, ref) and
             not is_map_key(state.callback_tasks, ref) and
             not is_map_key(state.subscription_open_tasks, ref) do
    case server_request_by_monitor(state.server_request_tasks, ref) do
      {callback_ref, callback} ->
        cancel_timeout(callback.timeout_ref)
        tasks = Map.delete(state.server_request_tasks, callback_ref)

        send_server_request_response(
          state,
          callback.id,
          {:error, Error.internal_error("client request handler exited")}
        )

        {:noreply, %{state | server_request_tasks: tasks}}

      nil ->
        handle_subscription_down(state, ref, worker, reason)
    end
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending_requests, id) do
      {%{from: from} = operation, pending} ->
        state = stop_operation_tasks(state, operation)
        state = %{state | pending_requests: pending}

        if connect_operation?(operation.kind) do
          continue_connect_after_timeout(from, state)
        else
          GenServer.reply(from, {:error, :timeout})
          {:noreply, state}
        end

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:connect_waiter_timeout, waiter_ref}, state) do
    {expired, waiting} =
      Enum.split_with(state.connect_waiters || [], &(&1.waiter_ref == waiter_ref))

    Enum.each(expired, &GenServer.reply(&1.from, {:error, :timeout}))
    {:noreply, %{state | connect_waiters: waiting}}
  end

  def handle_info({:callback_timeout, ref}, state) do
    case Map.pop(state.callback_tasks, ref) do
      {nil, _callback_tasks} ->
        {:noreply, state}

      {callback, callback_tasks} ->
        _ = Task.Supervisor.terminate_child(state.task_supervisor, callback.task_pid)
        GenServer.reply(callback.operation.from, {:error, :timeout})
        {:noreply, %{state | callback_tasks: callback_tasks}}
    end
  end

  def handle_info({:server_request_callback_result, ref, response}, state) do
    case Map.pop(state.server_request_tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {callback, tasks} ->
        cancel_timeout(callback.timeout_ref)
        Process.demonitor(callback.monitor_ref, [:flush])
        send_server_request_response(state, callback.id, response)
        {:noreply, %{state | server_request_tasks: tasks}}
    end
  end

  def handle_info({:server_request_callback_timeout, ref}, state) do
    case Map.pop(state.server_request_tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {callback, tasks} ->
        Process.demonitor(callback.monitor_ref, [:flush])
        _ = Task.Supervisor.terminate_child(state.server_request_supervisor, callback.pid)

        send_server_request_response(
          state,
          callback.id,
          {:error, Error.internal_error("client request handler timed out")}
        )

        {:noreply, %{state | server_request_tasks: tasks}}
    end
  end

  def handle_info({:subscription_open_timeout, ref}, state) do
    case Map.pop(state.subscription_open_tasks, ref) do
      {nil, _open_tasks} ->
        {:noreply, state}

      {operation, open_tasks} ->
        _ = Task.Supervisor.terminate_child(state.task_supervisor, operation.task_pid)

        state =
          discard_opening_subscription(%{state | subscription_open_tasks: open_tasks}, operation)

        GenServer.reply(operation.from, {:error, :timeout})
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    cond do
      Map.has_key?(state.transport_tasks, ref) ->
        Process.demonitor(ref, [:flush])
        finish_transport_task(ref, result, state)

      Map.has_key?(state.callback_tasks, ref) ->
        Process.demonitor(ref, [:flush])
        finish_callback_task(ref, result, state)

      Map.has_key?(state.subscription_open_tasks, ref) ->
        Process.demonitor(ref, [:flush])
        finish_subscription_open(ref, result, state)

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.transport_tasks, ref) do
    fail_transport_task(ref, {:transport_task_exit, reason}, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.callback_tasks, ref) do
    fail_callback_task(ref, reason, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.subscription_open_tasks, ref) do
    fail_subscription_open(ref, reason, state)
  end

  def handle_info(msg, state) do
    Logger.debug("MCP Client: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.transport_pid && state.status != :closed do
      state.transport_module.close(state.transport_pid)
    end
  catch
    _, _ -> :ok
  end

  # --- Response handling ---

  defp handle_response(%Response{id: id} = response, state) do
    case Map.fetch(state.subscriptions, id) do
      {:ok, subscription} ->
        finish_subscription_response(response, subscription, state)

      :error ->
        case Map.pop(state.pending_requests, id) do
          {%{timeout_ref: ref} = operation, pending} ->
            cancel_timeout(ref)
            state = detach_transport_task(%{state | pending_requests: pending}, operation)
            finish_response_with_operation(response, operation, state)

          {nil, _} ->
            handle_unknown_response(response, id, state)
        end
    end
  end

  defp handle_unknown_response(response, id, state) do
    if subscription_result?(response) do
      Logger.debug("MCP Client: final response for locally closed subscription id=#{inspect(id)}")
    else
      Logger.warning("MCP Client: response for unknown request id=#{inspect(id)}")
    end

    {:noreply, state}
  end

  defp finish_response_with_operation(
         %Response{error: %Error{code: -32_022, data: data}} = response,
         %{kind: {:discover, false}, deadline: deadline} = operation,
         state
       ) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case supported_protocol_version(data) do
      version when is_binary(version) and remaining > 0 and version != @protocol_version ->
        state = select_protocol(state, version)
        send_initialize(state, operation.from, remaining)

      version when is_binary(version) and remaining > 0 ->
        state = %{state | protocol_version: version}

        send_rpc_with_timeout(
          state,
          operation.from,
          Methods.discover(),
          %{},
          {:discover, true},
          [],
          remaining
        )

      _no_supported_version_or_time ->
        finish_response(response, operation.from, operation.kind, state)
    end
  end

  defp finish_response_with_operation(
         %Response{error: %Error{code: -32_601}},
         %{kind: {:discover, false}, deadline: deadline} = operation,
         state
       ) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      state = select_protocol(state, "2025-11-25")
      send_initialize(state, operation.from, remaining)
    else
      GenServer.reply(operation.from, {:error, :timeout})
      {:noreply, state}
    end
  end

  defp finish_response_with_operation(
         %Response{error: nil, result: result} = response,
         operation,
         state
       )
       when is_map(result) do
    if input_required?(result) and is_function(state.on_input_required, 1) do
      start_mrtr_callback(result, operation, state)
    else
      finish_response(response, operation.from, operation.kind, state)
    end
  end

  defp finish_response_with_operation(
         %Response{error: error},
         %{
           from: from,
           deadline: deadline,
           kind: {:tool_call, name, arguments, false, descriptors}
         },
         state
       )
       when not is_nil(error) do
    if recognized_custom_header_mismatch?(error, descriptors) do
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining > 0 do
        send_rpc_with_timeout(
          state,
          from,
          Methods.tools_list(),
          %{},
          {:tool_header_refresh, name, arguments, error, new_refresh_state(deadline)},
          [],
          remaining
        )
      else
        GenServer.reply(from, {:error, :timeout})
        {:noreply, state}
      end
    else
      GenServer.reply(from, {:error, error})
      {:noreply, state}
    end
  end

  defp finish_response_with_operation(response, operation, state),
    do: finish_response(response, operation.from, operation.kind, state)

  # server/discover result → capability probe reply.
  defp finish_response(%Response{error: error}, from, {:discover, _retried?}, state)
       when error != nil do
    fail_connect(from, error, state)
  end

  defp finish_response(%Response{result: result}, from, {:discover, _retried?}, state) do
    case decode_discover_result(result, state.protocol_version) do
      {:ok, discover} ->
        finish_discover(from, discover, state)

      {:error, reason} ->
        fail_connect(from, {:invalid_discover_result, reason}, state)
    end
  end

  defp finish_response(%Response{result: result}, from, :initialize, state) do
    case decode_initialize_result(result, state) do
      {:ok, initialize} ->
        case send_notification(state, Methods.initialized(), nil) do
          :ok -> complete_initialize(from, initialize, state)
          {:error, reason} -> rollback_initialize(from, reason, state)
        end

      {:error, reason} ->
        reset_transport_session(state)
        fail_connect(from, {:invalid_initialize_result, reason}, state)
    end
  end

  defp finish_response(%Response{result: result}, from, {:reinitialize, original}, state) do
    case decode_initialize_result(result, state) do
      {:ok, initialize} ->
        case send_notification(state, Methods.initialized(), nil) do
          :ok -> retry_after_reinitialize(from, initialize, original, state)
          {:error, reason} -> rollback_reinitialize(from, reason, state)
        end

      {:error, reason} ->
        reset_transport_session(state)
        GenServer.reply(from, {:error, {:invalid_initialize_result, reason}})
        {:noreply, %{state | legacy_ready: false}}
    end
  end

  # tools/call result → complete transparently through MRTR when input is required.
  defp finish_response(%Response{error: error} = _resp, from, _kind, state) when error != nil do
    GenServer.reply(from, {:error, error})
    {:noreply, state}
  end

  defp finish_response(
         %Response{result: result},
         from,
         {:tool_call, _name, _arguments, _refresh_attempted?, _descriptors},
         state
       ) do
    GenServer.reply(from, {:ok, result})
    {:noreply, state}
  end

  defp finish_response(
         %Response{result: result},
         from,
         {:tool_header_refresh, name, arguments, original_error, refresh},
         state
       ) do
    case tools_from_result(result, state) do
      {:ok, tools} ->
        state = cache_tools(state, tools)

        case Enum.find(tools, &(Map.get(&1, "name") == name)) do
          nil ->
            continue_tool_refresh(
              result,
              from,
              name,
              arguments,
              original_error,
              refresh,
              state
            )

          selected_tool ->
            state = cache_tools(state, [selected_tool])
            {descriptors, state} = cached_descriptors(state, name)
            retry_tool_call(state, from, name, arguments, descriptors, refresh.deadline)
        end

      {:error, reason} ->
        GenServer.reply(from, {:error, {:invalid_tools_result, reason}})
        {:noreply, state}
    end
  end

  defp finish_response(%Response{result: result}, from, :tools_list, state) do
    case tools_from_result(result, state) do
      {:ok, tools} ->
        state = if legacy_protocol?(state), do: state, else: cache_tools(state, tools)
        GenServer.reply(from, {:ok, Map.put(result, "tools", tools)})
        {:noreply, state}

      {:error, reason} ->
        GenServer.reply(from, {:error, {:invalid_tools_result, reason}})
        {:noreply, state}
    end
  end

  defp finish_response(%Response{result: result}, from, _kind, state) do
    GenServer.reply(from, {:ok, result})
    {:noreply, state}
  end

  defp finish_discover(from, discover, state) do
    result = %{
      server_info: discover.server_info,
      server_capabilities: discover.capabilities,
      protocol_version: state.protocol_version,
      instructions: discover.instructions
    }

    state = %{
      state
      | server_capabilities: discover.capabilities,
        server_info: discover.server_info,
        connect_result: result
    }

    complete_connect(from, result, state)
  end

  defp complete_initialize(from, initialize, state) do
    result = initialize_result(initialize)

    state = %{
      state
      | server_capabilities: initialize.capabilities,
        server_info: initialize.server_info,
        protocol_version: initialize.protocol_version,
        legacy_ready: true,
        connect_result: result
    }

    complete_connect(from, result, state)
  end

  defp initialize_result(initialize) do
    %{
      server_info: initialize.server_info,
      server_capabilities: initialize.capabilities,
      protocol_version: initialize.protocol_version,
      instructions: initialize.instructions
    }
  end

  defp complete_connect(from, result, state) do
    GenServer.reply(from, {:ok, result})
    reply_connect_waiters(state.connect_waiters, {:ok, result})
    {:noreply, %{state | connect_waiters: nil}}
  end

  defp fail_connect(from, reason, state) do
    GenServer.reply(from, {:error, reason})
    reply_connect_waiters(state.connect_waiters, {:error, reason})

    {:noreply,
     %{
       state
       | connect_waiters: nil,
         connect_result: nil,
         legacy_ready: false
     }}
  end

  defp continue_connect_after_timeout(from, state) do
    GenServer.reply(from, {:error, :timeout})
    now = System.monotonic_time(:millisecond)

    case Enum.max_by(state.connect_waiters || [], & &1.deadline, fn -> nil end) do
      nil ->
        {:noreply, %{state | connect_waiters: nil, connect_result: nil, legacy_ready: false}}

      waiter ->
        cancel_timeout(waiter.timeout_ref)
        remaining = max(waiter.deadline - now, 0)
        waiting = List.delete(state.connect_waiters, waiter)
        state = %{state | connect_waiters: waiting, connect_result: nil, legacy_ready: false}

        if legacy_protocol?(state) do
          send_initialize(state, waiter.from, remaining)
        else
          send_rpc(state, waiter.from, Methods.discover(), %{}, {:discover, false}, [], remaining)
        end
    end
  end

  defp rollback_initialize(from, reason, state) do
    reset_transport_session(state)
    fail_connect(from, {:initialized_notification_failed, reason}, state)
  end

  defp retry_after_reinitialize(from, initialize, original, state) do
    remaining = original.deadline - System.monotonic_time(:millisecond)

    state = %{
      state
      | server_capabilities: initialize.capabilities,
        server_info: initialize.server_info,
        protocol_version: initialize.protocol_version,
        legacy_ready: true
    }

    if remaining > 0 do
      send_rpc_with_timeout(
        state,
        from,
        original.method,
        original.params,
        original.kind,
        original.transport_opts,
        remaining,
        true
      )
    else
      GenServer.reply(from, {:error, :timeout})
      {:noreply, state}
    end
  end

  defp rollback_reinitialize(from, reason, state) do
    reset_transport_session(state)
    GenServer.reply(from, {:error, {:initialized_notification_failed, reason}})
    {:noreply, %{state | legacy_ready: false}}
  end

  defp recover_expired_session(operation, state) do
    remaining = operation.deadline - System.monotonic_time(:millisecond)
    reset_transport_session(state)
    state = %{state | legacy_ready: false}

    if remaining > 0 do
      original =
        operation
        |> Map.drop([:timeout_ref, :transport_ref, :transport_pid])
        |> Map.put(:recovery_attempted, true)

      send_initialize(state, operation.from, remaining, {:reinitialize, original})
    else
      GenServer.reply(operation.from, {:error, :timeout})
      {:noreply, state}
    end
  end

  defp reset_transport_session(state) do
    if function_exported?(state.transport_module, :reset_session, 1) do
      state.transport_module.reset_session(state.transport_pid)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp connect_operation?({:discover, _retried?}), do: true
  defp connect_operation?(:initialize), do: true
  defp connect_operation?(_kind), do: false

  defp legacy_not_ready_reply(state) do
    if legacy_protocol?(state),
      do: {:reply, {:error, :not_ready}, state},
      else: {:reply, {:error, :legacy_protocol_required}, state}
  end

  defp retry_tool_call(state, from, name, arguments, descriptors, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      send_rpc_with_timeout(
        state,
        from,
        Methods.tools_call(),
        name_args(name, arguments),
        {:tool_call, name, arguments, true, descriptors},
        [routing_headers: descriptors],
        remaining
      )
    else
      GenServer.reply(from, {:error, :timeout})
      {:noreply, state}
    end
  end

  defp valid_header_annotation_locations?(%{"name" => name} = tool) when is_binary(name) do
    valid? =
      case Map.fetch(tool, "inputSchema") do
        {:ok, %{"type" => "object"} = schema} ->
          match?({:ok, _descriptors}, ToolRouting.descriptors(schema))

        _missing_or_invalid ->
          false
      end

    unless valid? do
      Logger.warning(
        "MCP Client: excluding tool #{inspect(name)}: invalid inputSchema or x-mcp-header annotation"
      )
    end

    valid?
  end

  defp valid_header_annotation_locations?(tool) do
    Logger.warning("MCP Client: excluding malformed tool catalog entry: #{inspect(tool)}")
    false
  end

  defp tool_index_entry(%{"name" => name, "inputSchema" => schema}) do
    {:ok, descriptors} = ToolRouting.descriptors(schema)
    {name, descriptors}
  end

  defp cache_tools(state, tools) do
    Enum.reduce(tools, state, fn tool, acc ->
      {name, descriptors} = tool_index_entry(tool)
      order = Enum.reject(acc.tool_schema_order, &(&1 == name)) ++ [name]
      index = Map.put(acc.tool_schema_index, name, descriptors)
      trim_tool_index(%{acc | tool_schema_index: index, tool_schema_order: order})
    end)
  end

  defp trim_tool_index(state) when length(state.tool_schema_order) > state.tool_schema_limit do
    [evicted | order] = state.tool_schema_order

    %{
      state
      | tool_schema_index: Map.delete(state.tool_schema_index, evicted),
        tool_schema_order: order
    }
  end

  defp trim_tool_index(state), do: state

  defp cached_descriptors(state, name) do
    case Map.fetch(state.tool_schema_index, name) do
      {:ok, descriptors} ->
        order = Enum.reject(state.tool_schema_order, &(&1 == name)) ++ [name]
        {descriptors, %{state | tool_schema_order: order}}

      :error ->
        {[], state}
    end
  end

  defp selected_descriptors(state, name, nil) do
    {descriptors, state} = cached_descriptors(state, name)
    {:ok, descriptors, state}
  end

  defp selected_descriptors(state, _name, input_schema) do
    case ToolRouting.descriptors(input_schema) do
      {:ok, descriptors} -> {:ok, descriptors, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recognized_custom_header_mismatch?(error, _descriptors) do
    detail = error.data |> inspect() |> String.downcase()

    error.code == Error.header_mismatch_code() and
      String.contains?(detail, "mcp-param-")
  end

  defp tools_from_result(%{"tools" => tools}, %{legacy_adapter: adapter})
       when not is_nil(adapter) and is_list(tools),
       do: {:ok, tools}

  defp tools_from_result(result, _state) when is_map(result) do
    case Map.fetch(result, "tools") do
      {:ok, tools} when is_list(tools) ->
        {:ok, Enum.filter(tools, &valid_header_annotation_locations?/1)}

      {:ok, _invalid} ->
        {:error, :tools_must_be_a_list}

      :error ->
        {:error, :missing_tools}
    end
  end

  defp tools_from_result(_result, _state), do: {:error, :result_must_be_an_object}

  defp new_refresh_state(deadline) do
    %{
      seen_cursors: MapSet.new(),
      pages_remaining: @max_tool_refresh_pages,
      deadline: deadline
    }
  end

  defp continue_tool_refresh(
         result,
         from,
         name,
         arguments,
         original_error,
         refresh,
         state
       ) do
    cursor = Map.get(result, "nextCursor")
    remaining_timeout = refresh.deadline - System.monotonic_time(:millisecond)

    if is_binary(cursor) and refresh.pages_remaining > 0 and remaining_timeout > 0 and
         not MapSet.member?(refresh.seen_cursors, cursor) and caller_alive?(from) do
      next_refresh = %{
        refresh
        | seen_cursors: MapSet.put(refresh.seen_cursors, cursor),
          pages_remaining: refresh.pages_remaining - 1
      }

      send_rpc_with_timeout(
        state,
        from,
        Methods.tools_list(),
        %{"cursor" => cursor},
        {:tool_header_refresh, name, arguments, original_error, next_refresh},
        [],
        remaining_timeout
      )
    else
      GenServer.reply(from, {:error, original_error})
      {:noreply, state}
    end
  end

  defp caller_alive?({pid, _tag}) when is_pid(pid), do: Process.alive?(pid)

  defp input_required?(result), do: Map.get(result, "resultType") == MRTR.result_type()

  # Fulfil requested inputs outside the GenServer, bounded by the original
  # operation deadline. A callback failure affects only its request.
  defp start_mrtr_callback(result, operation, state) do
    remaining = operation.deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          state.on_input_required.(Map.get(result, "inputRequests"))
        end)

      timeout_ref = Process.send_after(self(), {:callback_timeout, task.ref}, remaining)

      callback = %{
        operation: operation,
        result: result,
        task_pid: task.pid,
        timeout_ref: timeout_ref
      }

      {:noreply, %{state | callback_tasks: Map.put(state.callback_tasks, task.ref, callback)}}
    else
      GenServer.reply(operation.from, {:error, :timeout})
      {:noreply, state}
    end
  end

  # --- Notifications ---

  defp handle_server_request(%Request{} = request, state) do
    cond do
      legacy_protocol?(state) and state.legacy_ready ->
        start_server_request_callback(request, state)

      legacy_protocol?(state) ->
        send_server_request_response(
          state,
          request.id,
          {:error, Error.internal_error("client is not initialized")}
        )

        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  defp start_server_request_callback(%Request{id: id, method: method, params: params}, state) do
    handler = Map.get(state.request_handlers, method)
    client = self()
    ref = make_ref()

    case Task.Supervisor.start_child(state.server_request_supervisor, fn ->
           response = invoke_server_request_handler(handler, method, params)
           send(client, {:server_request_callback_result, ref, response})
         end) do
      {:ok, pid} ->
        callback = %{
          id: id,
          pid: pid,
          monitor_ref: Process.monitor(pid),
          timeout_ref:
            Process.send_after(
              self(),
              {:server_request_callback_timeout, ref},
              state.server_request_timeout
            )
        }

        {:noreply,
         %{state | server_request_tasks: Map.put(state.server_request_tasks, ref, callback)}}

      {:error, :max_children} ->
        send_server_request_response(
          state,
          id,
          {:error, Error.internal_error("client request handler overloaded")}
        )

        {:noreply, state}

      {:error, reason} ->
        send_server_request_response(
          state,
          id,
          {:error, Error.internal_error("client request handler unavailable: #{inspect(reason)}")}
        )

        {:noreply, state}
    end
  end

  defp send_server_request_response(state, id, response) do
    message = server_request_response(id, response)

    _ =
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        state.transport_module.send_message(state.transport_pid, message)
      end)

    :ok
  end

  defp invoke_server_request_handler(nil, method, _params),
    do: {:error, Error.method_not_found(method)}

  defp invoke_server_request_handler(handler, method, params) when is_function(handler, 2),
    do: safely_invoke(fn -> handler.(method, params) end)

  defp invoke_server_request_handler(handler, _method, params) when is_function(handler, 1),
    do: safely_invoke(fn -> handler.(params) end)

  defp safely_invoke(callback) do
    callback.()
  rescue
    exception ->
      Logger.error(
        "MCP client request handler failed " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, Error.internal_error("client request handler failed")}
  catch
    kind, reason ->
      Logger.error(
        "MCP client request handler failed " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      {:error, Error.internal_error("client request handler failed")}
  end

  defp server_request_response(id, {:ok, result}),
    do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp server_request_response(id, {:error, %Error{} = error}) do
    body = %{"code" => error.code, "message" => error.message}
    body = if is_nil(error.data), do: body, else: Map.put(body, "data", error.data)
    %{"jsonrpc" => "2.0", "id" => id, "error" => body}
  end

  defp server_request_response(id, _invalid),
    do:
      server_request_response(id, {:error, Error.internal_error("invalid client handler result")})

  defp handle_notification(%Notification{method: method, params: params}, state) do
    case subscription_id(params) do
      nil ->
        dispatch_notification(state, state.notification_handler, method, params)
        {:noreply, state}

      id ->
        route_subscription_notification(id, method, params, state)
    end
  end

  defp dispatch_notification(_state, nil, method, _params),
    do: Logger.debug("MCP Client: unhandled notification: #{method}")

  defp dispatch_notification(_state, pid, method, params) when is_pid(pid),
    do: send(pid, {:mcp_notification, method, params})

  defp dispatch_notification(state, fun, method, params) when is_function(fun, 2) do
    case Task.Supervisor.start_child(state.notification_supervisor, fn -> fun.(method, params) end) do
      {:ok, _pid} ->
        :ok

      {:error, :max_children} ->
        Logger.warning("MCP Client: notification handler saturated")

      {:error, reason} ->
        Logger.warning("MCP Client: notification handler failed: #{inspect(reason)}")
    end

    :ok
  end

  # --- Subscriptions ---

  defp open_subscription(%{subscription_supervisor: nil} = state, _from, _filter, _opts),
    do: {:reply, {:error, :subscriptions_not_configured}, state}

  defp open_subscription(state, from, filter, opts) do
    queue_limit = Keyword.get(opts, :queue_limit, state.subscription_queue_limit)
    owner = elem(from, 0)
    {id, next_state} = next_id(state)

    case SubscriptionWorker.start(state.subscription_supervisor, id, owner,
           queue_limit: queue_limit
         ) do
      {:ok, worker} ->
        start_subscription_request(next_state, from, id, worker, filter, opts)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp start_subscription_request(state, from, id, worker, filter, opts) do
    params =
      ListenParams.to_map(%ListenParams{notifications: filter})
      |> put_meta(Keyword.get(opts, :meta))

    message = encode(Request.new(id, Methods.subscriptions_listen(), with_meta(params, state)))
    timeout = Keyword.fetch!(opts, :open_timeout)

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        open_subscription_request(state, message)
      end)

    timeout_ref = Process.send_after(self(), {:subscription_open_timeout, task.ref}, timeout)
    monitor_ref = Process.monitor(worker)

    subscription = %{
      worker: worker,
      monitor_ref: monitor_ref,
      acknowledged?: false
    }

    operation = %{
      from: from,
      id: id,
      worker: worker,
      task_pid: task.pid,
      timeout_ref: timeout_ref
    }

    {:noreply,
     %{
       state
       | subscription_open_tasks: Map.put(state.subscription_open_tasks, task.ref, operation),
         subscriptions: Map.put(state.subscriptions, id, subscription)
     }}
  end

  defp finish_subscription_open(ref, result, state) do
    {operation, open_tasks} = Map.pop(state.subscription_open_tasks, ref)
    cancel_timeout(operation.timeout_ref)
    state = %{state | subscription_open_tasks: open_tasks}

    case result do
      :ok ->
        handle = SubscriptionHandle.new(operation.id, operation.worker)
        GenServer.reply(operation.from, {:ok, handle})
        {:noreply, state}

      {:error, reason} ->
        state = discard_opening_subscription(state, operation)
        GenServer.reply(operation.from, {:error, reason})
        {:noreply, state}

      other ->
        state = discard_opening_subscription(state, operation)
        GenServer.reply(operation.from, {:error, {:invalid_transport_result, other}})
        {:noreply, state}
    end
  end

  defp fail_subscription_open(ref, reason, state) do
    {operation, open_tasks} = Map.pop(state.subscription_open_tasks, ref)
    cancel_timeout(operation.timeout_ref)

    state =
      discard_opening_subscription(%{state | subscription_open_tasks: open_tasks}, operation)

    GenServer.reply(operation.from, {:error, {:transport_task_exit, reason}})
    {:noreply, state}
  end

  defp discard_opening_subscription(state, operation) do
    case Map.pop(state.subscriptions, operation.id) do
      {nil, subscriptions} ->
        %{state | subscriptions: subscriptions}

      {subscription, subscriptions} ->
        Process.demonitor(subscription.monitor_ref, [:flush])
        GenServer.stop(operation.worker, :normal)
        %{state | subscriptions: subscriptions}
    end
  end

  defp route_subscription_notification(id, method, params, state) do
    case Map.fetch(state.subscriptions, id) do
      {:ok, %{acknowledged?: false} = subscription}
      when method == @subscription_ack_method ->
        acknowledge_subscription(id, method, params, subscription, state)

      {:ok, %{acknowledged?: false}} ->
        fail_subscription(state, id, :notification_before_acknowledgment)

      {:ok, %{acknowledged?: true}}
      when method == @subscription_ack_method ->
        fail_subscription(state, id, :duplicate_acknowledgment)

      {:ok, %{acknowledged?: true} = subscription} ->
        case SubscriptionWorker.enqueue(subscription.worker, notification_map(method, params)) do
          :ok -> {:noreply, state}
          {:error, reason} -> fail_subscription(state, id, reason)
        end

      :error ->
        Logger.warning("MCP Client: notification for unknown subscription id=#{inspect(id)}")
        {:noreply, state}
    end
  end

  defp acknowledge_subscription(id, method, params, subscription, state) when is_map(params) do
    acknowledged = AcknowledgedParams.from_map(params)

    if subscription_id(acknowledged.meta) == id do
      case SubscriptionWorker.enqueue(subscription.worker, notification_map(method, params)) do
        :ok ->
          updated = %{subscription | acknowledged?: true}
          {:noreply, %{state | subscriptions: Map.put(state.subscriptions, id, updated)}}

        {:error, reason} ->
          fail_subscription(state, id, reason)
      end
    else
      fail_subscription(state, id, :acknowledgment_id_mismatch)
    end
  rescue
    error in [ArgumentError, KeyError, FunctionClauseError] ->
      fail_subscription(state, id, {:invalid_acknowledgment, Exception.message(error)})
  end

  defp acknowledge_subscription(id, _method, _params, _subscription, state),
    do: fail_subscription(state, id, :invalid_acknowledgment)

  defp finish_subscription_response(%Response{id: id, error: error}, subscription, state)
       when not is_nil(error) do
    state = remove_subscription(state, id, subscription)
    SubscriptionWorker.fail(subscription.worker, error)
    {:noreply, state}
  end

  defp finish_subscription_response(
         %Response{id: id, result: result},
         %{acknowledged?: true} = subscription,
         state
       )
       when is_map(result) do
    listen_result = ListenResult.from_map(result)

    if subscription_id(listen_result.meta) == id do
      state = remove_subscription(state, id, subscription)
      SubscriptionWorker.complete(subscription.worker, listen_result)
      {:noreply, state}
    else
      fail_subscription(state, id, :result_id_mismatch)
    end
  rescue
    error in [ArgumentError, KeyError, FunctionClauseError] ->
      fail_subscription(state, id, {:invalid_subscription_result, Exception.message(error)})
  end

  defp finish_subscription_response(
         %Response{id: id},
         %{acknowledged?: true},
         state
       ),
       do: fail_subscription(state, id, :invalid_subscription_result)

  defp finish_subscription_response(%Response{id: id}, _subscription, state),
    do: fail_subscription(state, id, :result_before_acknowledgment)

  defp fail_subscription(state, id, reason) do
    case Map.pop(state.subscriptions, id) do
      {nil, _subscriptions} ->
        {:noreply, state}

      {subscription, subscriptions} ->
        Process.demonitor(subscription.monitor_ref, [:flush])
        opening? = Enum.any?(state.subscription_open_tasks, fn {_ref, op} -> op.id == id end)

        if opening? do
          GenServer.stop(subscription.worker, :normal)
        else
          SubscriptionWorker.fail(subscription.worker, reason)
          send_subscription_cancel(state, id, "subscription protocol error")
        end

        fail_opening_subscription(%{state | subscriptions: subscriptions}, id, reason)
    end
  end

  defp fail_opening_subscription(state, id, reason) do
    case Enum.find(state.subscription_open_tasks, fn {_ref, operation} -> operation.id == id end) do
      nil ->
        {:noreply, state}

      {ref, operation} ->
        cancel_timeout(operation.timeout_ref)
        Process.demonitor(ref, [:flush])
        _ = Task.Supervisor.terminate_child(state.task_supervisor, operation.task_pid)
        GenServer.reply(operation.from, {:error, reason})

        {:noreply,
         %{state | subscription_open_tasks: Map.delete(state.subscription_open_tasks, ref)}}
    end
  end

  defp opening_subscription?(state, id) do
    Enum.any?(state.subscription_open_tasks, fn {_ref, operation} -> operation.id == id end)
  end

  defp handle_subscription_down(state, ref, worker, reason) do
    case subscription_by_monitor(state.subscriptions, ref, worker) do
      {id, _subscription} ->
        state = %{state | subscriptions: Map.delete(state.subscriptions, id)}

        if opening_subscription?(state, id) do
          fail_opening_subscription(state, id, {:subscription_worker_exit, reason})
        else
          send_subscription_cancel(state, id, "subscription consumer closed")
          {:noreply, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  defp remove_subscription(state, id, subscription) do
    Process.demonitor(subscription.monitor_ref, [:flush])
    %{state | subscriptions: Map.delete(state.subscriptions, id)}
  end

  defp subscription_by_monitor(subscriptions, ref, worker) do
    Enum.find(subscriptions, fn {_id, subscription} ->
      subscription.monitor_ref == ref and subscription.worker == worker
    end)
  end

  defp server_request_by_monitor(tasks, monitor_ref) do
    Enum.find(tasks, fn {_ref, callback} -> callback.monitor_ref == monitor_ref end)
  end

  defp subscription_id(%{"io.modelcontextprotocol/subscriptionId" => id}), do: id

  defp subscription_id(%{"_meta" => meta}) when is_map(meta) do
    Map.get(meta, "io.modelcontextprotocol/subscriptionId")
  end

  defp subscription_id(_params), do: nil

  defp notification_map(method, params) do
    encode(Notification.new(method, params))
  end

  defp subscription_result?(%Response{id: id, result: result}) when is_map(result) do
    subscription_id(result) == id
  end

  defp subscription_result?(_response), do: false

  defp send_subscription_cancel(%{status: :ready} = state, id, reason) do
    result =
      try do
        if function_exported?(state.transport_module, :cancel_subscription, 2) do
          state.transport_module.cancel_subscription(state.transport_pid, id)
        else
          params = %{"requestId" => id, "reason" => reason}
          send_notification(state, Methods.cancelled(), params)
        end
      rescue
        exception -> {:error, {:transport_exception, exception}}
      catch
        :exit, transport_reason -> {:error, {:transport_exit, transport_reason}}
      end

    case result do
      :ok ->
        :ok

      {:error, error} ->
        Logger.warning("MCP Client: subscription cancellation failed: #{inspect(error)}")

      other ->
        Logger.warning("MCP Client: subscription cancellation returned: #{inspect(other)}")
    end
  end

  defp send_subscription_cancel(_state, _id, _reason), do: :ok

  # --- Sending ---

  defp send_rpc(state, from, method, params, kind, transport_opts, timeout) do
    send_rpc_with_timeout(
      state,
      from,
      method,
      params,
      kind,
      transport_opts,
      timeout || state.request_timeout
    )
  end

  defp send_rpc_with_timeout(state, from, method, params, kind, transport_opts, timeout),
    do: send_rpc_with_timeout(state, from, method, params, kind, transport_opts, timeout, false)

  defp send_rpc_with_timeout(
         state,
         from,
         method,
         params,
         kind,
         transport_opts,
         timeout,
         recovery_attempted
       ) do
    {id, state} = next_id(state)
    timeout_ref = schedule_timeout(id, timeout)
    deadline = System.monotonic_time(:millisecond) + timeout

    operation = %{
      from: from,
      timeout_ref: timeout_ref,
      kind: kind,
      deadline: deadline,
      method: method,
      params: params,
      transport_opts: transport_opts,
      recovery_attempted: recovery_attempted
    }

    state = put_pending(state, id, operation)

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        send_request(state, id, method, with_meta(params, state), transport_opts)
      end)

    pending =
      Map.update!(state.pending_requests, id, fn operation ->
        operation
        |> Map.put(:transport_ref, task.ref)
        |> Map.put(:transport_pid, task.pid)
      end)

    {:noreply,
     %{
       state
       | pending_requests: pending,
         transport_tasks: Map.put(state.transport_tasks, task.ref, id)
     }}
  end

  # Every request carries the per-request _meta the stateless server needs in
  # place of the removed handshake (SEP-2575): protocol version + client
  # identity/capabilities. `server/discover` also carries it harmlessly.
  defp with_meta(params, %{legacy_adapter: adapter}) when not is_nil(adapter),
    do: params

  defp with_meta(params, state) do
    reserved = %{
      "io.modelcontextprotocol/protocolVersion" => state.protocol_version,
      "io.modelcontextprotocol/clientInfo" => encode(state.client_info),
      "io.modelcontextprotocol/clientCapabilities" => encode(state.client_capabilities)
    }

    meta = Map.merge(Map.get(params, "_meta", %{}), reserved)
    Map.put(params, "_meta", meta)
  end

  defp send_request(state, id, method, params, opts) do
    message = encode(Request.new(id, method, params))

    if function_exported?(state.transport_module, :send_message, 3) do
      state.transport_module.send_message(state.transport_pid, message, opts)
    else
      state.transport_module.send_message(state.transport_pid, message)
    end
  end

  defp open_subscription_request(state, message) do
    if function_exported?(state.transport_module, :open_subscription, 3) do
      state.transport_module.open_subscription(state.transport_pid, message, [])
    else
      state.transport_module.send_message(state.transport_pid, message)
    end
  end

  defp send_notification(state, method, params) do
    state.transport_module.send_message(
      state.transport_pid,
      encode(Notification.new(method, params))
    )
  end

  defp encode(struct), do: Jason.decode!(Jason.encode!(struct))

  defp put_pending(state, id, operation),
    do: %{state | pending_requests: Map.put(state.pending_requests, id, operation)}

  defp finish_transport_task(ref, result, state) do
    {id, transport_tasks} = Map.pop(state.transport_tasks, ref)
    state = %{state | transport_tasks: transport_tasks}

    case {id, result} do
      {nil, _result} ->
        {:noreply, state}

      {id, :ok} ->
        pending =
          Map.update(state.pending_requests, id, nil, fn operation ->
            Map.drop(operation, [:transport_ref, :transport_pid])
          end)

        {:noreply, %{state | pending_requests: pending}}

      {id, {:error, reason}} ->
        fail_pending_transport(state, id, reason)

      {id, other} ->
        fail_pending_transport(state, id, {:invalid_transport_result, other})
    end
  end

  defp fail_transport_task(ref, reason, state) do
    {id, transport_tasks} = Map.pop(state.transport_tasks, ref)
    state = %{state | transport_tasks: transport_tasks}

    if id, do: fail_pending_transport(state, id, reason), else: {:noreply, state}
  end

  defp fail_pending_transport(state, id, reason) do
    case Map.pop(state.pending_requests, id) do
      {%{from: from, timeout_ref: timeout_ref} = operation, pending} ->
        cancel_timeout(timeout_ref)
        state = %{state | pending_requests: pending}

        cond do
          reason == :session_expired and legacy_protocol?(state) and
            not operation.recovery_attempted and operation.kind not in [:initialize] ->
            recover_expired_session(operation, state)

          connect_operation?(operation.kind) ->
            fail_connect(from, reason, state)

          true ->
            GenServer.reply(from, {:error, reason})
            {:noreply, state}
        end

      {nil, _pending} ->
        {:noreply, state}
    end
  end

  defp finish_callback_task(ref, responses, state) do
    {callback, callback_tasks} = Map.pop(state.callback_tasks, ref)
    state = %{state | callback_tasks: callback_tasks}

    if callback && is_map(responses) do
      cancel_timeout(callback.timeout_ref)
      remaining = callback.operation.deadline - System.monotonic_time(:millisecond)

      if remaining > 0 do
        params =
          callback.operation.params
          |> Map.put("inputResponses", responses)
          |> maybe_put_request_state(callback.result)

        send_rpc_with_timeout(
          state,
          callback.operation.from,
          callback.operation.method,
          params,
          callback.operation.kind,
          callback.operation.transport_opts,
          remaining
        )
      else
        GenServer.reply(callback.operation.from, {:error, :timeout})
        {:noreply, state}
      end
    else
      if callback do
        cancel_timeout(callback.timeout_ref)

        GenServer.reply(
          callback.operation.from,
          {:error, {:invalid_input_responses, responses}}
        )
      end

      {:noreply, state}
    end
  end

  defp fail_callback_task(ref, reason, state) do
    {callback, callback_tasks} = Map.pop(state.callback_tasks, ref)
    state = %{state | callback_tasks: callback_tasks}

    if callback do
      cancel_timeout(callback.timeout_ref)
      GenServer.reply(callback.operation.from, {:error, {:callback_failed, reason}})
    end

    {:noreply, state}
  end

  defp detach_transport_task(state, operation) do
    case Map.get(operation, :transport_ref) do
      nil ->
        state

      ref ->
        Process.demonitor(ref, [:flush])
        %{state | transport_tasks: Map.delete(state.transport_tasks, ref)}
    end
  end

  defp stop_operation_tasks(state, operation) do
    if pid = Map.get(operation, :transport_pid) do
      _ = Task.Supervisor.terminate_child(state.task_supervisor, pid)
    end

    transport_tasks =
      case Map.get(operation, :transport_ref) do
        nil -> state.transport_tasks
        ref -> Map.delete(state.transport_tasks, ref)
      end

    %{state | transport_tasks: transport_tasks}
  end

  defp next_id(state), do: {state.next_id, %{state | next_id: state.next_id + 1}}
  defp schedule_timeout(id, ms), do: Process.send_after(self(), {:request_timeout, id}, ms)
  defp cancel_timeout(ref), do: Process.cancel_timer(ref)

  defp reply_connect_waiters(waiters, reply) do
    Enum.each(waiters || [], fn waiter ->
      cancel_timeout(waiter.timeout_ref)
      GenServer.reply(waiter.from, reply)
    end)
  end

  defp cursor_params(opts) do
    params = if cursor = Keyword.get(opts, :cursor), do: %{"cursor" => cursor}, else: %{}
    put_meta(params, Keyword.get(opts, :meta))
  end

  defp put_meta(params, nil), do: params
  defp put_meta(params, meta) when is_map(meta), do: Map.put(params, "_meta", meta)

  defp validate_call_options(opts) when is_list(opts) do
    with :ok <- validate_timeout(Keyword.get(opts, :timeout)) do
      case Keyword.get(opts, :meta) do
        nil -> :ok
        meta when is_map(meta) -> :ok
        meta -> {:error, {:invalid_meta, meta}}
      end
    end
  end

  defp validate_timeout(nil), do: :ok
  defp validate_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: :ok
  defp validate_timeout(timeout), do: {:error, {:invalid_timeout, timeout}}

  defp name_args(name, arguments) do
    params = %{"name" => name}
    if arguments && arguments != %{}, do: Map.put(params, "arguments", arguments), else: params
  end

  defp start_transport({module, opts}) do
    case module.start_link([{:owner, self()} | opts]) do
      {:ok, pid} -> {:ok, module, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_transport_protocol_version(
         {MCP.Transport.StreamableHTTP.Client, opts},
         protocol_version
       ) do
    {MCP.Transport.StreamableHTTP.Client, Keyword.put(opts, :protocol_version, protocol_version)}
  end

  defp put_transport_protocol_version(transport_spec, _protocol_version), do: transport_spec

  defp build_client_info(%Implementation{} = impl), do: impl

  defp build_client_info(map) when is_map(map) do
    %Implementation{
      name: Map.get(map, :name) || Map.get(map, "name", "mcp_elixir_sdk"),
      version: Map.get(map, :version) || Map.get(map, "version", "1.0.0")
    }
  end

  defp default_info, do: %{name: "mcp_elixir_sdk", version: "1.0.0"}

  defp validate_start_options(opts) do
    with :ok <- validate_tool_schema_limit(opts),
         :ok <- validate_positive_option(opts, :request_timeout, @default_request_timeout),
         :ok <-
           validate_positive_option(
             opts,
             :subscription_queue_limit,
             @default_subscription_queue_limit
           ),
         :ok <-
           validate_positive_option(
             opts,
             :notification_concurrency,
             @default_notification_concurrency
           ),
         :ok <-
           validate_positive_option(
             opts,
             :server_request_concurrency,
             @default_server_request_concurrency
           ),
         :ok <-
           validate_positive_option(
             opts,
             :server_request_timeout,
             @default_server_request_timeout
           ),
         :ok <- validate_client_capabilities(opts),
         do: validate_callback_configuration(opts)
  end

  defp validate_tool_schema_limit(opts) do
    limit = Keyword.get(opts, :tool_schema_limit, 1_024)

    if is_integer(limit) and limit >= 0,
      do: :ok,
      else: {:error, {:invalid_tool_schema_limit, limit}}
  end

  defp validate_positive_option(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0,
      do: :ok,
      else: {:error, {invalid_option_error(key), value}}
  end

  defp invalid_option_error(:request_timeout), do: :invalid_request_timeout
  defp invalid_option_error(:subscription_queue_limit), do: :invalid_subscription_queue_limit
  defp invalid_option_error(:notification_concurrency), do: :invalid_notification_concurrency

  defp invalid_option_error(:server_request_concurrency),
    do: :invalid_server_request_concurrency

  defp invalid_option_error(:server_request_timeout), do: :invalid_server_request_timeout

  defp validate_client_capabilities(opts) do
    capabilities = Keyword.get(opts, :client_capabilities, %ClientCapabilities{})
    _encoded = capabilities |> normalize_client_capabilities() |> ClientCapabilities.to_map()
    :ok
  rescue
    exception in [ArgumentError, FunctionClauseError] ->
      {:error, {:invalid_client_capabilities, Exception.message(exception)}}
  end

  defp validate_callback_configuration(opts) do
    {automatic_capabilities, automatic_handlers} = legacy_callback_config(opts)

    capabilities =
      case Keyword.fetch(opts, :client_capabilities) do
        {:ok, configured} -> normalize_client_capabilities(configured)
        :error -> automatic_capabilities
      end

    configured_handlers = Keyword.get(opts, :request_handlers, %{})

    with :ok <- validate_legacy_callbacks(opts),
         :ok <- validate_request_handlers(configured_handlers) do
      handlers = Map.merge(automatic_handlers, configured_handlers)

      validate_callback_capabilities(opts, capabilities, handlers)
    end
  end

  defp validate_callback_capabilities(opts, capabilities, handlers) do
    if Revision.legacy?(Keyword.get(opts, :protocol_version, @protocol_version)) do
      [
        {Methods.sampling_create_message(), capabilities.sampling},
        {Methods.roots_list(), capabilities.roots},
        {Methods.elicitation_create(), capabilities.elicitation}
      ]
      |> Enum.find_value(:ok, &callback_capability_error(&1, handlers))
    else
      :ok
    end
  end

  defp callback_capability_error({method, capability}, handlers) do
    handler? = valid_request_handler?(Map.get(handlers, method))
    capability? = not is_nil(capability)

    if handler? == capability?,
      do: false,
      else: {:error, {:callback_capability_mismatch, method}}
  end

  defp validate_legacy_callbacks(opts) do
    Enum.find_value([:on_sampling, :on_roots_list, :on_elicitation], :ok, fn key ->
      case Keyword.get(opts, key) do
        nil -> false
        callback when is_function(callback, 1) -> false
        callback -> {:error, {:invalid_client_callback, key, callback}}
      end
    end)
  end

  defp validate_request_handlers(handlers) when is_map(handlers) do
    case Enum.find(handlers, fn
           {method, handler} when is_binary(method) -> not valid_request_handler?(handler)
           _invalid -> true
         end) do
      nil -> :ok
      invalid -> {:error, {:invalid_request_handlers, invalid}}
    end
  end

  defp validate_request_handlers(handlers),
    do: {:error, {:invalid_request_handlers, handlers}}

  defp valid_request_handler?(handler),
    do: is_function(handler, 1) or is_function(handler, 2)

  defp normalize_client_capabilities(%ClientCapabilities{} = capabilities), do: capabilities

  defp normalize_client_capabilities(capabilities) when is_map(capabilities) do
    ClientCapabilities.from_map(capabilities)
  end

  defp legacy_callback_config(opts) do
    sampling = Keyword.get(opts, :on_sampling)
    roots = Keyword.get(opts, :on_roots_list)
    elicitation = Keyword.get(opts, :on_elicitation)

    capabilities = %ClientCapabilities{
      sampling: if(is_function(sampling, 1), do: %SamplingCapabilities{}),
      roots: if(is_function(roots, 1), do: %RootCapabilities{list_changed: true}),
      elicitation:
        if(is_function(elicitation, 1), do: %ElicitationCapabilities{form: %{}, url: %{}})
    }

    handlers =
      %{}
      |> maybe_put_handler(Methods.sampling_create_message(), sampling)
      |> maybe_put_handler(Methods.roots_list(), roots)
      |> maybe_put_handler(Methods.elicitation_create(), elicitation)

    {capabilities, handlers}
  end

  defp maybe_put_handler(handlers, _method, nil), do: handlers
  defp maybe_put_handler(handlers, method, callback), do: Map.put(handlers, method, callback)

  defp supported_protocol_version(%{"supported" => versions}) when is_list(versions),
    do: Enum.find(Protocol.supported_versions(), &(&1 in versions))

  defp supported_protocol_version(_data), do: nil

  defp decode_discover_result(result, protocol_version) when is_map(result) do
    discover = Discover.Result.from_map(result)

    cond do
      not is_list(discover.supported_versions) ->
        {:error, :supported_versions_must_be_an_array}

      not Enum.all?(discover.supported_versions, &is_binary/1) ->
        {:error, :supported_versions_must_contain_strings}

      protocol_version not in discover.supported_versions ->
        {:error, {:protocol_version_not_advertised, protocol_version}}

      true ->
        {:ok, discover}
    end
  rescue
    error in [ArgumentError, KeyError, FunctionClauseError] ->
      {:error, Exception.message(error)}
  end

  defp decode_discover_result(_result, _protocol_version), do: {:error, :result_must_be_an_object}

  defp send_initialize(state, from, timeout, kind \\ :initialize) do
    params = state.legacy_adapter.initialize_params(state.client_info, state.client_capabilities)

    send_rpc(state, from, Methods.initialize(), params, kind, [], timeout)
  end

  defp decode_initialize_result(result, state) when is_map(result) do
    initialize = Initialize.Result.from_map(result)

    case state.legacy_adapter.validate_initialize_result(result) do
      :ok ->
        {:ok, initialize}

      {:error, {:unexpected_protocol_version, version}} ->
        {:error, {:unsupported_protocol_version, version}}
    end
  rescue
    error in [ArgumentError, KeyError, FunctionClauseError] ->
      {:error, Exception.message(error)}
  end

  defp decode_initialize_result(_result, _state), do: {:error, :result_must_be_an_object}

  defp legacy_protocol?(state), do: not is_nil(state.legacy_adapter)

  defp legacy_adapter(version) do
    case Revision.fetch(version) do
      {:ok, adapter} when adapter != :stateless -> adapter
      _other -> nil
    end
  end

  defp select_protocol(state, version),
    do: %{state | protocol_version: version, legacy_adapter: legacy_adapter(version)}

  defp maybe_put_request_state(params, result) do
    if Map.has_key?(result, "requestState") do
      Map.put(params, "requestState", Map.get(result, "requestState"))
    else
      Map.delete(params, "requestState")
    end
  end

  defp do_close(state) do
    state = fail_all_operations(state, :closed)

    Enum.each(state.subscriptions, fn {_id, subscription} ->
      Process.demonitor(subscription.monitor_ref, [:flush])
      SubscriptionWorker.fail(subscription.worker, :closed)
    end)

    closed_state = %{state | status: :closed, subscriptions: %{}}

    case close_transport(state) do
      :ok -> {:stop, :normal, :ok, closed_state}
      {:error, reason} -> close_failure(closed_state, :exit, reason, [])
    end
  rescue
    exception -> close_failure(state, :error, exception, __STACKTRACE__)
  catch
    kind, reason -> close_failure(state, kind, reason, __STACKTRACE__)
  end

  defp close_failure(state, kind, reason, stacktrace) do
    Logger.error("MCP client close failed " <> Exception.format(kind, reason, stacktrace))

    {:stop, :normal, {:error, {:close_failed, {kind, reason}}},
     %{state | status: :closed, subscriptions: %{}}}
  end

  defp close_transport(%{transport_pid: nil}), do: :ok

  defp close_transport(state) do
    case state.transport_module.close(state.transport_pid) do
      :ok -> :ok
      {:error, reason} -> {:error, {:transport_close_failed, reason}}
      other -> {:error, {:invalid_transport_close_result, other}}
    end
  end

  defp fail_all_operations(state, reason) do
    Enum.each(state.pending_requests, fn {_id, operation} ->
      cancel_timeout(operation.timeout_ref)

      if pid = Map.get(operation, :transport_pid) do
        _ = Task.Supervisor.terminate_child(state.task_supervisor, pid)
      end

      GenServer.reply(operation.from, {:error, reason})
    end)

    Enum.each(state.callback_tasks, fn {_ref, callback} ->
      cancel_timeout(callback.timeout_ref)
      _ = Task.Supervisor.terminate_child(state.task_supervisor, callback.task_pid)
      GenServer.reply(callback.operation.from, {:error, reason})
    end)

    Enum.each(state.server_request_tasks, fn {_ref, callback} ->
      cancel_timeout(callback.timeout_ref)
      Process.demonitor(callback.monitor_ref, [:flush])
      _ = Task.Supervisor.terminate_child(state.server_request_supervisor, callback.pid)
    end)

    reply_connect_waiters(state.connect_waiters, {:error, reason})

    Enum.each(state.subscription_open_tasks, fn {_ref, operation} ->
      cancel_timeout(operation.timeout_ref)
      _ = Task.Supervisor.terminate_child(state.task_supervisor, operation.task_pid)
      GenServer.stop(operation.worker, :normal)
      GenServer.reply(operation.from, {:error, reason})
    end)

    %{
      state
      | pending_requests: %{},
        transport_tasks: %{},
        callback_tasks: %{},
        server_request_tasks: %{},
        connect_waiters: nil,
        subscription_open_tasks: %{}
    }
  end

  defp list_all(client, operation, items_key, opts),
    do: do_list_all(client, operation, items_key, opts, nil, [])

  defp do_list_all(client, operation, items_key, opts, cursor, acc) do
    call_opts = if cursor, do: Keyword.put(opts, :cursor, cursor), else: opts

    case apply_list_operation(client, operation, call_opts) do
      {:ok, result} ->
        items = Map.get(result, Atom.to_string(items_key), [])
        new_acc = acc ++ items

        case Map.get(result, "nextCursor") do
          nil -> {:ok, new_acc}
          next_cursor -> do_list_all(client, operation, items_key, opts, next_cursor, new_acc)
        end

      {:error, _} = error ->
        error
    end
  end

  defp apply_list_operation(client, :list_tools, opts), do: list_tools(client, opts)
  defp apply_list_operation(client, :list_resources, opts), do: list_resources(client, opts)

  defp apply_list_operation(client, :list_resource_templates, opts),
    do: list_resource_templates(client, opts)

  defp apply_list_operation(client, :list_prompts, opts), do: list_prompts(client, opts)
end
