defmodule MCP.Transport.StreamableHTTP.Plug do
  @moduledoc """
  Dual-era Plug endpoint for the MCP Streamable HTTP transport.

  The preferred 2026 path is a thin **per-request driver** for
  `MCP.Server.Dispatch`: there is no
  `initialize` handshake, no `Mcp-Session-Id`, and no session affinity — any
  request is serviceable by any instance behind a round-robin balancer
  (SEP-2575 / SEP-2567). The dispatch `config` is built once at `init/1`; every
  request builds its own `MCP.Server.ToolContext` and calls `Dispatch`.

  The compatibility 2025 path creates an isolated OTP session at initialize,
  requires `Mcp-Session-Id` afterward, serves server messages via GET SSE, and
  closes on DELETE. Both paths share the endpoint without sharing lifecycle
  state.

  ## Usage

      plug = MCP.Transport.StreamableHTTP.Plug.new(server_mod: MyApp.Handler)
      {:ok, _} = Bandit.start_link(plug: plug, port: 8080)

  ## Per-request pipeline (strict order)

    1. **Enforcement** — configured Host/Origin policy (and any host auth) runs first, on
       every request, before the identity factory (MC-5 / AC7). A rejected
       request never runs the factory.
    2. **Decode + request metadata** — parse the JSON-RPC body and validate the
       required 2026-07-28 `_meta` fields.
    3. **Standard routing headers** — validate
       `Mcp-Method` / `Mcp-Name` against it (SEP-2243) — mismatch → `-32020`.
    4. **Identity resolution** — the `:handler_opts` factory is evaluated
       against *this request's* `conn` (or the static keyword's `:identity`);
       the result populates `ToolContext.identity`, never from `params`
       (MC-2/Comment B, MC-3, MC-4). Factory failure → controlled `-32603`,
       no dispatch (MC-6).
    5. **Custom routing headers** — resolve the selected tool schema using the
       authenticated identity and validate recognized `Mcp-Param-*` values.
    6. **Dispatch** — `Dispatch.dispatch(message, ctx, config)`.

  ## Options

    * `:server_mod` (required) — the `MCP.Server.Handler` module.
    * `:server_opts` — `:server_info`, `:instructions`, `:cache_defaults`
      forwarded to `MCP.Server.Config`. If you raise `:cache_defaults` above the
      no-store default on identity-dependent results, set `cacheScope: "private"`
      — see the security warning on `MCP.Server.Config.build/2`.
    * `:handler_opts` — static `keyword()` **or** a `(Plug.Conn.t() ->
      keyword())` factory. The factory is evaluated **per request** for 2026,
      and at session initialization plus every session-bound request for 2025.
      The initialized identity is fingerprinted and subsequent requests must
      resolve to the same principal before the session is dispatched.
      The static form's `:identity` is used as a constant. (The non-identity
      base is passed once to `Handler.init/1` at mount.)

      > #### Factory last-mile responsibility {: .warning}
      >
      > The factory receives the **whole** `conn`, which carries **both**
      > authenticated material (assigns your upstream auth Plug set) **and**
      > model-reachable material (raw request headers, the request body). The
      > invariant's last mile is yours: read the **authenticated** part only.
      >
      >     # RIGHT — an assign established server-side by your auth pipeline:
      >     handler_opts: fn conn -> [identity: conn.assigns[:current_user]] end
      >
      >     # WRONG — a raw header is caller-supplied and unauthenticated;
      >     # anyone (including the model) can set it, defeating the invariant:
      >     handler_opts: fn conn -> [identity: get_req_header(conn, "x-user")] end
      >
      > This is the one identity-leak path the SDK cannot close by construction:
      > it drops model-controlled `params`/`arguments`/`_meta` and never reads a
      > header into identity itself, but it cannot tell which part of the `conn`
      > **your** factory chooses to trust. Read `conn.assigns`, not raw input.
    * `:enable_json_response` — return `application/json` instead of SSE for
      request/response (default: false).
    * `:max_body_length` — maximum accepted POST body size in bytes (default:
      `8_000_000`). Larger or multi-chunk bodies are rejected with HTTP 413
      before JSON decoding.
    * `:allowed_hosts` — exact canonical host names accepted by the endpoint.
      Defaults to localhost names only. Configure the Phoenix endpoint host
      explicitly for a deployed gateway, for example `["tower.example"]`.
    * `:allowed_origins` — HTTP(S) scheme/host origins accepted when an
      `Origin` header is present; ports are normalized so local ephemeral ports
      remain usable. Defaults to loopback HTTP/HTTPS origins. Non-browser
      clients may omit `Origin`, but every request must still have an allowed
      Host.
    * `:legacy_session_limit` and `:legacy_sessions_per_identity` — endpoint
      and authenticated-principal session caps (defaults: 1,024 and 16).
    * `:legacy_session_idle_timeout` and `:legacy_session_absolute_timeout` —
      stateful-session expiry in milliseconds (defaults: 15 minutes and 24
      hours). Expiry terminates both owned session processes.
    * `:legacy_session_manager` — registered runtime manager name. The SDK
      application starts the default manager; custom managers must be
      supervised by the host application.
    * `:legacy_endpoint_owner` — registered process name monitored for endpoint
      shutdown (default: `MCPElixirSDK.Supervisor`). A Phoenix deployment
      should set this to its endpoint's registered name so stopping that
      endpoint immediately reclaims its legacy sessions.
    * `:protocol_version` — advertised version (default: the stateless core's).
    * `:tool_schemas` — either `%{tool_name => input_schema}` or a
      `(tool_name, identity -> input_schema | nil)` resolver. Static schemas
      are compiled and validated at mount. The resolver runs after identity
      resolution, allowing identity-dependent catalogs without invoking
      `handle_list_tools/3` as a routing side effect. It must return the same
      selected schema that the handler advertises from `tools/list`.

  ## Security

  Identity must be established server-side by the authenticated Plug pipeline
  (e.g. an upstream auth Plug setting `conn.assigns`) and resolved by the
  factory — never supplied by the model via tool-call arguments. The handler
  stays transport-agnostic: it reads `ctx.identity`; the `conn` is never leaked
  into a handler callback. A factory that raises or returns a non-keyword
  yields a clean `-32603` (HTTP 500) with no handler invoked; the detail is
  logged server-side and never returned to the client.

  ### Cache-scope footgun warning

  When `handler_opts` resolves a per-caller identity **and** `:cache_defaults`
  would stamp `ttlMs > 0` with `cacheScope: "public"` onto the cacheable
  list/read results, `init/1` logs a one-time warning: identity-dependent data
  authorised for a shared cache can be served across principals. Set a
  `"private"` scope (or keep `ttlMs` at 0) for identity-dependent results.

  The warning is emitted from `init/1`, so it fires **once per configuration,
  never per request**. Note the surfacing depends on when your deployment runs
  `init/1`: `Bandit`/`Plug.Cowboy` started with `plug: {#{inspect(__MODULE__)},
  opts}` call it at **server startup** (the warning reaches the runtime log —
  this SDK's documented shape). A module-based pipeline that mounts this plug
  with `plug_init_mode: :compile` (a Phoenix production default) runs `init/1`
  at **compile time**, so the warning would appear in the build log instead;
  set `plug_init_mode: :runtime`, or prefer the Bandit `plug: {Module, opts}`
  form, if you mount it that way.
  """

  @behaviour Plug

  require Logger

  alias MCP.Protocol
  alias MCP.Protocol.Error
  alias MCP.Protocol.Messages.{Request, Response}
  alias MCP.Protocol.Messages.Subscriptions.ListenParams
  alias MCP.Protocol.Meta
  alias MCP.Protocol.ToolRouting
  alias MCP.Protocol.Types.SubscriptionFilter

  alias MCP.Server.{
    Config,
    Dispatch,
    LegacyDispatch,
    NotificationCollector,
    SubscriptionWorker,
    ToolContext
  }

  alias MCP.Transport.SSE
  alias MCP.Transport.StreamableHTTP.LegacySession
  alias MCP.Transport.StreamableHTTP.LegacySessionManager

  @typedoc """
  Options threaded into the handler's identity resolution: a static keyword
  list, or a factory `(Plug.Conn.t() -> keyword())` evaluated per request.
  """
  @type handler_opts :: keyword() | (Plug.Conn.t() -> keyword())

  defstruct [
    :server_mod,
    :server_opts,
    :handler_opts,
    :enable_json_response,
    :protocol_version,
    :tool_schemas,
    :subscription_supervisor,
    :subscription_registry,
    :subscription_endpoint,
    :subscription_queue_limit,
    :subscription_keepalive_interval,
    :max_body_length,
    :legacy_session_manager,
    :legacy_endpoint_id,
    :legacy_endpoint_owner,
    :legacy_session_limit,
    :legacy_sessions_per_identity,
    :legacy_session_idle_timeout,
    :legacy_session_absolute_timeout,
    :legacy_sse_timeout,
    :allowed_hosts,
    :allowed_origins,
    :config,
    :collector_start,
    :max_notifications_per_request,
    :max_notification_bytes
  ]

  @localhost_patterns ~w(localhost 127.0.0.1 ::1)
  @doc """
  Creates a Plug configuration tuple suitable for Bandit.
  """
  def new(opts), do: {__MODULE__, opts}

  # --- Plug callbacks ---

  @impl Plug
  def init(%__MODULE__{} = config), do: config

  def init(opts) do
    server_mod = Keyword.fetch!(opts, :server_mod)
    server_opts = Keyword.get(opts, :server_opts, [])
    handler_opts = validate_handler_opts!(Keyword.get(opts, :handler_opts, []))
    enable_json_response = Keyword.get(opts, :enable_json_response, false)
    protocol_version = Keyword.get(opts, :protocol_version, Dispatch.protocol_version())
    tool_schemas = compile_tool_schemas!(Keyword.get(opts, :tool_schemas, %{}))
    subscription_supervisor = Keyword.get(opts, :subscription_supervisor)
    subscription_registry = Keyword.get(opts, :subscription_registry)
    subscription_endpoint = Keyword.get(opts, :subscription_endpoint, server_mod)
    subscription_queue_limit = Keyword.get(opts, :subscription_queue_limit, 256)
    subscription_keepalive_interval = Keyword.get(opts, :subscription_keepalive_interval, 15_000)
    max_body_length = Keyword.get(opts, :max_body_length, 8_000_000)
    max_notifications_per_request = Keyword.get(opts, :max_notifications_per_request, 256)
    max_notification_bytes = Keyword.get(opts, :max_notification_bytes, 1_000_000)
    legacy_sse_timeout = Keyword.get(opts, :legacy_sse_timeout, 25_000)
    legacy_session_manager = Keyword.get(opts, :legacy_session_manager, LegacySessionManager)
    legacy_endpoint_id = Keyword.get(opts, :legacy_endpoint_id, UUID.uuid4())
    legacy_endpoint_owner = Keyword.get(opts, :legacy_endpoint_owner, MCPElixirSDK.Supervisor)
    legacy_session_limit = Keyword.get(opts, :legacy_session_limit, 1_024)
    legacy_sessions_per_identity = Keyword.get(opts, :legacy_sessions_per_identity, 16)
    legacy_session_idle_timeout = Keyword.get(opts, :legacy_session_idle_timeout, 15 * 60_000)

    legacy_session_absolute_timeout =
      Keyword.get(opts, :legacy_session_absolute_timeout, 24 * 60 * 60_000)

    allowed_hosts = Keyword.get(opts, :allowed_hosts, @localhost_patterns)

    allowed_origins =
      Keyword.get(opts, :allowed_origins, [
        "http://localhost",
        "https://localhost",
        "http://127.0.0.1",
        "https://127.0.0.1",
        "http://[::1]",
        "https://[::1]"
      ])

    unless is_integer(max_body_length) and max_body_length > 0 do
      raise ArgumentError, ":max_body_length must be a positive integer"
    end

    validate_positive_integer!(max_notifications_per_request, :max_notifications_per_request)
    validate_positive_integer!(max_notification_bytes, :max_notification_bytes)

    unless is_integer(legacy_sse_timeout) and legacy_sse_timeout > 0 do
      raise ArgumentError, ":legacy_sse_timeout must be a positive integer"
    end

    validate_positive_integer!(legacy_session_limit, :legacy_session_limit)
    validate_positive_integer!(legacy_sessions_per_identity, :legacy_sessions_per_identity)
    validate_positive_integer!(legacy_session_idle_timeout, :legacy_session_idle_timeout)
    validate_positive_integer!(legacy_session_absolute_timeout, :legacy_session_absolute_timeout)
    validate_string_list!(allowed_hosts, :allowed_hosts)
    validate_origin_list!(allowed_origins)

    validate_subscription_options!(
      subscription_supervisor,
      subscription_registry,
      subscription_queue_limit,
      subscription_keepalive_interval
    )

    # Injectable per-request collector start (MES-14 MC-6). Defaults to the real
    # collector; a 0-arity fun returning `{:ok, pid} | {:error, reason}`. The
    # seam exists so the MC-6 clean-failure path (a collector that fails to
    # start) is exercised by a permanent test rather than a manual injection.
    collector_start = Keyword.get(opts, :collector_start, &NotificationCollector.start_link/0)

    # AC7 (MES-14): config-time cache-scope footgun warning. init/1 runs once
    # per plug configuration (call/2 has no path here), so this emits at most
    # once regardless of request volume.
    warn_if_public_cache_of_identity_scoped(handler_opts, server_opts)

    # Build the immutable dispatch config once. Only the non-identity static
    # base reaches Handler.init/1; per-request identity rides ToolContext.
    static_base = if is_function(handler_opts), do: [], else: handler_opts

    config_opts =
      [
        handler_opts: static_base,
        subscriptions_enabled:
          not is_nil(subscription_supervisor) and not is_nil(subscription_registry)
      ] ++
        Keyword.take(server_opts, [
          :server_info,
          :instructions,
          :cache_defaults,
          :extensions,
          :skills_callback_timeout
        ])

    dispatch_config =
      case Config.build(server_mod, config_opts) do
        {:ok, config} -> config
        {:error, reason} -> raise "MCP Plug: handler init failed: #{inspect(reason)}"
      end

    %__MODULE__{
      server_mod: server_mod,
      server_opts: server_opts,
      handler_opts: handler_opts,
      enable_json_response: enable_json_response,
      protocol_version: protocol_version,
      tool_schemas: tool_schemas,
      subscription_supervisor: subscription_supervisor,
      subscription_registry: subscription_registry,
      subscription_endpoint: subscription_endpoint,
      subscription_queue_limit: subscription_queue_limit,
      subscription_keepalive_interval: subscription_keepalive_interval,
      max_body_length: max_body_length,
      legacy_session_manager: legacy_session_manager,
      legacy_endpoint_id: legacy_endpoint_id,
      legacy_endpoint_owner: legacy_endpoint_owner,
      legacy_session_limit: legacy_session_limit,
      legacy_sessions_per_identity: legacy_sessions_per_identity,
      legacy_session_idle_timeout: legacy_session_idle_timeout,
      legacy_session_absolute_timeout: legacy_session_absolute_timeout,
      legacy_sse_timeout: legacy_sse_timeout,
      allowed_hosts: allowed_hosts,
      allowed_origins: allowed_origins,
      config: dispatch_config,
      collector_start: collector_start,
      max_notifications_per_request: max_notifications_per_request,
      max_notification_bytes: max_notification_bytes
    }
  end

  @impl Plug
  def call(conn, config) do
    # Step 1 — enforcement precedes everything (MC-5 / AC7).
    if allowed_request?(conn, config) do
      route_method(conn, config)
    else
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(403, "Forbidden: non-localhost origin")
    end
  end

  @doc "Returns active legacy session IDs and their server connection pids."
  @spec legacy_sessions(%__MODULE__{}) ::
          [{String.t(), pid()}] | {:error, {:session_manager_unavailable, term()}}
  def legacy_sessions(%__MODULE__{} = config) do
    LegacySessionManager.list(config.legacy_session_manager, config.legacy_endpoint_id)
  catch
    :exit, reason -> {:error, {:session_manager_unavailable, reason}}
  end

  defp route_method(conn, config) do
    case conn.method do
      "POST" -> handle_post(conn, config)
      "GET" -> handle_get(conn, config)
      "DELETE" -> handle_legacy_delete(conn, config)
      _ -> method_not_allowed(conn)
    end
  end

  # --- POST: the request/response path ---

  defp handle_post(conn, config) do
    with {:ok, body, conn} <-
           Plug.Conn.read_body(conn,
             length: config.max_body_length,
             read_length: min(config.max_body_length, 1_000_000)
           ),
         {:ok, message} <- Jason.decode(body) do
      handle_decoded_post(conn, config, message)
    else
      {:more, _partial_body, conn} ->
        send_json_error(
          conn,
          413,
          Error.invalid_request_code(),
          "Request body too large",
          "request body exceeds configured maximum"
        )

      {:error, %Jason.DecodeError{}} ->
        send_json_error(conn, 400, Error.parse_error_code(), "Parse error", "invalid_json")

      {:error, reason} ->
        send_json_error(
          conn,
          400,
          Error.invalid_request_code(),
          "Invalid request",
          invalid_request_detail(reason)
        )
    end
  end

  defp handle_decoded_post(conn, config, message) when is_map(message) do
    cond do
      stateless_initialize?(conn, message) ->
        send_json_error(
          conn,
          404,
          Error.method_not_found_code(),
          "Method not found",
          "initialize is not part of 2026-07-28",
          Map.get(message, "id")
        )

      legacy_request?(conn, message) ->
        handle_legacy_post(conn, config, message)

      true ->
        handle_stateless_post(conn, config, message)
    end
  end

  defp handle_decoded_post(conn, _config, _message) do
    send_json_error(conn, 400, Error.invalid_request_code(), "Invalid request", "expected object")
  end

  defp handle_stateless_post(conn, config, message) do
    with :ok <- validate_message_shape(message),
         :ok <- validate_required_request_meta(message),
         :ok <- check_routing_headers(conn, message),
         {:ok, identity} <- resolve_identity(config.handler_opts, conn),
         :ok <- check_custom_routing_headers(conn, message, config.tool_schemas, identity),
         {:ok, decoded} <- Protocol.decode_message(message) do
      dispatch(conn, config, decoded, message, identity)
    else
      {:error, {:routing_mismatch, detail}} ->
        send_json_error(
          conn,
          400,
          Error.header_mismatch_code(),
          "Header mismatch",
          detail,
          Map.get(message, "id")
        )

      {:error, {:invalid_params, detail}} ->
        send_json_error(
          conn,
          400,
          Error.invalid_params_code(),
          "Invalid params",
          inspect(detail),
          Map.get(message, "id")
        )

      {:error, {:factory_failed, reason}} ->
        Logger.error("MCP Plug: handler_opts factory failed: #{inspect(reason)}")

        send_json_error(
          conn,
          500,
          Error.internal_error_code(),
          "Internal error",
          "handler_opts factory error",
          Map.get(message, "id")
        )

      {:error, reason} ->
        send_json_error(
          conn,
          400,
          Error.invalid_request_code(),
          "Invalid request",
          invalid_request_detail(reason),
          Map.get(message, "id")
        )
    end
  end

  defp legacy_request?(conn, message) do
    first_header(conn, "mcp-protocol-version") in LegacyDispatch.protocol_versions() or
      (Map.get(message, "method") == "initialize" and
         is_nil(first_header(conn, "mcp-protocol-version"))) or
      not is_nil(first_header(conn, "mcp-session-id"))
  end

  defp stateless_initialize?(conn, %{"method" => "initialize"}) do
    first_header(conn, "mcp-protocol-version") == Dispatch.protocol_version()
  end

  defp stateless_initialize?(_conn, _message), do: false

  defp handle_legacy_post(conn, config, %{"method" => "initialize"} = message) do
    with {:ok, %Request{}} <- Protocol.decode_message(message),
         :ok <- reject_initialize_session_header(conn),
         {:ok, handler_opts} <- resolve_handler_options(config.handler_opts, conn),
         identity = Keyword.get(handler_opts, :identity),
         {:ok, session_id, response, notifications} <-
           start_and_initialize_legacy(config, handler_opts, identity, message) do
      if Map.has_key?(response, "result") do
        conn
        |> Plug.Conn.put_resp_header("mcp-session-id", session_id)
        |> send_response(config, response, notifications)
      else
        delete_legacy_session(config, session_id)
        send_response(conn, config, response, notifications)
      end
    else
      {:error, {:factory_failed, reason}} ->
        Logger.error("MCP Plug: legacy handler_opts factory failed: #{inspect(reason)}")

        send_json_error(
          conn,
          500,
          Error.internal_error_code(),
          "Internal error",
          "handler_opts factory error",
          Map.get(message, "id")
        )

      {:manager_error, reason} ->
        legacy_session_manager_error(conn, reason)

      {:error, reason} when reason in [:session_limit, :identity_limit, :endpoint_unavailable] ->
        send_json_error(
          conn,
          503,
          Error.internal_error_code(),
          "Session capacity reached",
          Atom.to_string(reason),
          Map.get(message, "id")
        )

      {:error, reason} ->
        send_json_error(
          conn,
          400,
          Error.invalid_request_code(),
          "Invalid request",
          invalid_request_detail(reason),
          Map.get(message, "id")
        )
    end
  end

  defp handle_legacy_post(conn, config, message) do
    session_id = first_header(conn, "mcp-session-id")

    with {:ok, presented_version} <- validate_legacy_protocol_header(conn),
         {:ok, handler_opts} <- resolve_handler_options(config.handler_opts, conn),
         identity = Keyword.get(handler_opts, :identity),
         {:ok, session} <- legacy_session(config, session_id, identity, handler_opts),
         :ok <- validate_session_protocol(session, presented_version) do
      dispatch_legacy_http(conn, config, message, session)
    else
      {:error, {:factory_failed, reason}} -> legacy_identity_resolution_error(conn, reason)
      {:error, detail} -> legacy_protocol_header_error(conn, message, detail)
      {:identity_error, _detail} -> Plug.Conn.send_resp(conn, 403, "Forbidden")
      {:manager_error, reason} -> legacy_session_manager_error(conn, reason)
      :error -> send_json_error(conn, 404, -32_000, "Session not found", session_id)
    end
  end

  defp dispatch_legacy_http(conn, config, message, session) do
    case LegacySession.deliver(session, message, config.legacy_sse_timeout) do
      {:ok, response, notifications} ->
        send_response(conn, config, response, notifications)

      :accepted ->
        Plug.Conn.send_resp(conn, 202, "")

      {:error, :timeout} ->
        send_json_error(
          conn,
          504,
          Error.internal_error_code(),
          "Request timeout",
          "legacy session did not respond",
          Map.get(message, "id")
        )

      {:error, reason} ->
        send_json_error(
          conn,
          400,
          Error.invalid_request_code(),
          "Invalid request",
          invalid_request_detail(reason),
          Map.get(message, "id")
        )
    end
  end

  defp handle_legacy_delete(conn, config) do
    session_id = first_header(conn, "mcp-session-id")

    with {:ok, presented_version} <- validate_legacy_protocol_header(conn),
         {:ok, handler_opts} <- resolve_handler_options(config.handler_opts, conn),
         identity = Keyword.get(handler_opts, :identity),
         {:ok, session} <- legacy_session(config, session_id, identity, handler_opts),
         :ok <- validate_session_protocol(session, presented_version),
         :ok <- delete_legacy_session(config, session_id) do
      Plug.Conn.send_resp(conn, 200, "")
    else
      {:error, {:factory_failed, reason}} -> legacy_identity_resolution_error(conn, reason)
      {:error, detail} -> legacy_protocol_header_error(conn, %{}, detail)
      {:identity_error, _detail} -> Plug.Conn.send_resp(conn, 403, "Forbidden")
      {:manager_error, reason} -> legacy_session_manager_error(conn, reason)
      :error -> send_json_error(conn, 404, -32_000, "Session not found", session_id)
    end
  end

  defp validate_legacy_protocol_header(conn) do
    case first_header(conn, "mcp-protocol-version") do
      nil ->
        {:error, "missing MCP-Protocol-Version"}

      version ->
        if version in LegacyDispatch.protocol_versions(),
          do: {:ok, version},
          else: {:error, "unsupported MCP-Protocol-Version: #{inspect(version)}"}
    end
  end

  defp validate_session_protocol(
         %{server: server, transport: transport, protocol_version: version},
         version
       )
       when is_pid(server) and is_pid(transport),
       do: :ok

  defp validate_session_protocol(%{protocol_version: expected}, presented),
    do: {:error, "session protocol mismatch: expected #{expected}, got #{presented}"}

  defp legacy_protocol_header_error(conn, message, detail) do
    send_json_error(
      conn,
      400,
      Error.unsupported_protocol_version_code(),
      "Unsupported protocol version",
      detail,
      Map.get(message, "id")
    )
  end

  defp legacy_identity_resolution_error(conn, reason) do
    Logger.error("MCP Plug: legacy identity resolution failed: #{inspect(reason)}")
    send_json_error(conn, 500, Error.internal_error_code(), "Internal error", nil)
  end

  defp legacy_session_manager_error(conn, reason) do
    Logger.error("MCP Plug: legacy session manager unavailable: #{inspect(reason)}")
    send_json_error(conn, 503, Error.internal_error_code(), "Session manager unavailable", nil)
  end

  defp legacy_session(_config, nil, _identity, _authorization_context), do: :error

  defp legacy_session(config, session_id, identity, authorization_context) do
    case LegacySessionManager.lookup(
           config.legacy_session_manager,
           config.legacy_endpoint_id,
           session_id,
           identity,
           authorization_context
         ) do
      {:ok, session} -> {:ok, session}
      {:error, :identity_mismatch} -> {:identity_error, :identity_mismatch}
      :error -> :error
    end
  catch
    :exit, reason -> {:manager_error, reason}
  end

  defp delete_legacy_session(config, session_id) do
    LegacySessionManager.delete(
      config.legacy_session_manager,
      config.legacy_endpoint_id,
      session_id
    )
  catch
    :exit, reason -> {:manager_error, reason}
  end

  defp resolve_handler_options(handler_opts, conn) when is_function(handler_opts, 1) do
    case handler_opts.(conn) do
      opts when is_list(opts) ->
        if Keyword.keyword?(opts),
          do: {:ok, opts},
          else: {:error, {:factory_failed, :not_keyword}}

      _other ->
        {:error, {:factory_failed, :not_keyword}}
    end
  rescue
    exception -> {:error, {:factory_failed, {:raised, exception, __STACKTRACE__}}}
  catch
    kind, reason -> {:error, {:factory_failed, {kind, reason}}}
  end

  defp resolve_handler_options(handler_opts, _conn) when is_list(handler_opts),
    do: {:ok, handler_opts}

  defp start_legacy_session(config, handler_opts, identity, protocol_version) do
    server_opts =
      Keyword.take(config.server_opts, [:server_info, :instructions, :request_timeout])

    limits = [
      session_limit: config.legacy_session_limit,
      per_identity_limit: config.legacy_sessions_per_identity,
      idle_timeout: config.legacy_session_idle_timeout,
      absolute_timeout: config.legacy_session_absolute_timeout,
      endpoint_owner: config.legacy_endpoint_owner,
      protocol_version: protocol_version,
      authorization_context: handler_opts
    ]

    LegacySessionManager.create(
      config.legacy_session_manager,
      config.legacy_endpoint_id,
      identity,
      config.server_mod,
      handler_opts,
      server_opts,
      limits
    )
  catch
    :exit, reason -> {:manager_error, reason}
  end

  defp start_and_initialize_legacy(config, handler_opts, identity, message) do
    protocol_version = get_in(message, ["params", "protocolVersion"])

    with true <- protocol_version in LegacyDispatch.protocol_versions(),
         {:ok, session_id, session} <-
           start_legacy_session(config, handler_opts, identity, protocol_version) do
      case LegacySession.deliver(session, message, config.legacy_sse_timeout) do
        {:ok, response, notifications} ->
          {:ok, session_id, response, notifications}

        {:error, reason} ->
          delete_legacy_session(config, session_id)
          {:error, reason}
      end
    else
      false -> {:error, {:unsupported_protocol_version, protocol_version}}
      error -> error
    end
  end

  defp validate_message_shape(%{"method" => method} = message) when is_binary(method) do
    params = Map.get(message, "params", %{})

    cond do
      not is_map(params) ->
        {:error, :params_must_be_an_object}

      Map.has_key?(params, "_meta") and not is_map(Map.get(params, "_meta")) ->
        {:error, :meta_must_be_an_object}

      method == "tools/call" and Map.has_key?(params, "arguments") and
          not is_map(Map.get(params, "arguments")) ->
        {:error, :arguments_must_be_an_object}

      true ->
        :ok
    end
  end

  defp validate_message_shape(_message), do: :ok

  defp validate_required_request_meta(%{"id" => _id, "method" => _method} = message) do
    case message |> Map.get("params") |> Meta.from_params() |> Meta.validate_required() do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_params, reason}}
    end
  end

  defp validate_required_request_meta(_message), do: :ok

  # Starts the per-request notification collector, mapping a start failure to a
  # controlled error rather than crashing on an unguarded match.
  defp start_collector(start_fun, config) do
    case start_fun.() do
      {:ok, collector} = ok ->
        :ok =
          NotificationCollector.configure(collector,
            max_notifications: config.max_notifications_per_request,
            max_bytes: config.max_notification_bytes
          )

        ok

      {:error, reason} ->
        {:error, {:collector_start_failed, reason}}
    end
  end

  # The stateless core issues no server-to-client requests, so a response has
  # nothing to correlate. It is still a valid routing-header-free JSON-RPC
  # message and receives the same empty acknowledgment as on stdio.
  defp dispatch(conn, _config, %Response{}, _raw_message, _identity) do
    Plug.Conn.send_resp(conn, 202, "")
  end

  defp dispatch(
         conn,
         config,
         %Request{method: "subscriptions/listen", params: params, id: id},
         _raw_message,
         identity
       ) do
    open_subscription_stream(conn, config, id, params, identity)
  end

  defp dispatch(conn, config, decoded, raw_message, identity) do
    case start_collector(config.collector_start, config) do
      {:ok, collector} ->
        dispatch(conn, config, decoded, raw_message, identity, collector)

      {:error, {:collector_start_failed, reason}} ->
        Logger.error("MCP Plug: notification collector failed to start: #{inspect(reason)}")

        send_json_error(
          conn,
          500,
          Error.internal_error_code(),
          "Internal error",
          "notification collector unavailable",
          Map.get(raw_message, "id")
        )
    end
  end

  defp dispatch(conn, config, decoded, raw_message, identity, collector) do
    # The notification collector is a per-request process (MES-14): its pid is
    # held only by this request's reply_sink closure on `ctx`. No later request
    # can name it, so a prior request's notifications are unaddressable — not
    # merely cleared (AC2, reachability-bounded). This replaces the Sprint 3
    # process-dictionary collector whose process-keyed slot leaked across
    # same-process requests (evidence-log I10). `start_link` (in the with-chain)
    # links the collector to this request process, so it dies with a crashing
    # request; `stop/1` in the `after` is prompt cleanup, not the safety
    # guarantee.
    ctx = %ToolContext{
      request_id: Map.get(raw_message, "id"),
      meta: get_in(raw_message, ["params", "_meta"]),
      identity: identity,
      reply_sink: fn method, params -> NotificationCollector.push(collector, method, params) end
    }

    try do
      case Dispatch.dispatch(decoded, ctx, config.config) do
        {:reply, response} ->
          if NotificationCollector.overflowed?(collector) do
            send_json_error(
              conn,
              500,
              Error.internal_error_code(),
              "Internal error",
              "notification limit reached",
              Map.get(raw_message, "id")
            )
          else
            send_response(conn, config, response, NotificationCollector.drain(collector))
          end

        :noreply ->
          Plug.Conn.send_resp(conn, 202, "")
      end
    after
      NotificationCollector.stop(collector)
    end
  end

  # --- GET: empty event stream (no standing session stream in stateless mode) ---

  defp handle_get(conn, config) do
    if accepts_sse?(conn) do
      case first_header(conn, "mcp-session-id") do
        nil -> send_empty_sse(conn)
        session_id -> handle_legacy_get(conn, config, session_id)
      end
    else
      send_json_error(conn, 406, -32_000, "Not Acceptable", "Must accept text/event-stream")
    end
  end

  defp handle_legacy_get(conn, config, session_id) do
    with {:ok, presented_version} <- validate_legacy_protocol_header(conn),
         {:ok, handler_opts} <- resolve_handler_options(config.handler_opts, conn),
         identity = Keyword.get(handler_opts, :identity),
         {:ok, session} <- legacy_session(config, session_id, identity, handler_opts),
         :ok <- validate_session_protocol(session, presented_version) do
      case LegacySession.next_event(session, config.legacy_sse_timeout) do
        {:ok, message} ->
          send_legacy_sse(conn, SSE.encode_message(message))

        {:error, :timeout} ->
          send_legacy_sse(conn, "")

        {:error, :closed} ->
          send_json_error(conn, 404, -32_000, "Session closed", session_id)

        {:error, _reason} ->
          send_json_error(conn, 503, -32_603, "Session unavailable", "session_unavailable")
      end
    else
      {:error, {:factory_failed, reason}} -> legacy_identity_resolution_error(conn, reason)
      {:error, detail} -> legacy_protocol_header_error(conn, %{}, detail)
      {:identity_error, _detail} -> Plug.Conn.send_resp(conn, 403, "Forbidden")
      {:manager_error, reason} -> legacy_session_manager_error(conn, reason)
      :error -> send_json_error(conn, 404, -32_000, "Session not found", session_id)
    end
  end

  defp send_legacy_sse(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.put_resp_header("cache-control", "no-cache")
    |> Plug.Conn.send_resp(200, body)
  end

  defp send_empty_sse(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.put_resp_header("cache-control", "no-cache")
    |> Plug.Conn.send_resp(200, "")
  end

  # --- Routing headers (SEP-2243) ---

  # Routing headers are required on JSON-RPC requests. They must match the
  # request body, and `Mcp-Name` must decode to the request's
  # **method-appropriate** target (SEP-2243, §"Mcp-Name":
  # `params.name` for `tools/call`/`prompts/get`, `params.uri` for
  # `resources/read`). Enables gateways to route without inspecting the body.
  defp check_routing_headers(conn, %{"id" => _id, "method" => method} = message) do
    params = Map.get(message, "params", %{})
    version = get_in(params, ["_meta", "io.modelcontextprotocol/protocolVersion"])

    with {:ok, header_version} <- required_header(conn, "mcp-protocol-version"),
         :ok <- matching_header("mcp-protocol-version", header_version, version),
         {:ok, header_method} <- required_header(conn, "mcp-method"),
         :ok <- matching_header("mcp-method", header_method, method) do
      check_name_header(conn, method, params)
    end
  end

  defp check_routing_headers(_conn, _message), do: :ok

  defp required_header(conn, name) do
    case first_header(conn, name) do
      nil -> {:error, {:routing_mismatch, "missing required #{name} header"}}
      value -> {:ok, value}
    end
  end

  defp matching_header(_name, value, value), do: :ok

  defp matching_header(name, _header_value, _body_value),
    do: {:error, {:routing_mismatch, "#{name} does not match request body"}}

  defp check_name_header(conn, method, params)
       when method in ["tools/call", "prompts/get", "resources/read"] do
    target = routing_target(method, params)

    with {:ok, header_name} <- required_header(conn, "mcp-name"),
         {:ok, decoded_name} <- decode_header_value(header_name) do
      matching_header("mcp-name", decoded_name, target)
    end
  end

  defp check_name_header(conn, _method, _params) do
    case first_header(conn, "mcp-name") do
      nil -> :ok
      value -> {:error, {:routing_mismatch, "unexpected mcp-name header #{inspect(value)}"}}
    end
  end

  defp decode_header_value("=?base64?" <> encoded_with_suffix = value) do
    if String.ends_with?(encoded_with_suffix, "?=") do
      encoded = binary_part(encoded_with_suffix, 0, byte_size(encoded_with_suffix) - 2)

      with {:ok, decoded} <- Base.decode64(encoded),
           true <- String.valid?(decoded) do
        {:ok, decoded}
      else
        _ -> {:error, {:routing_mismatch, "invalid Base64-sentinel mcp-name header"}}
      end
    else
      decode_plain_header_value(value)
    end
  end

  defp decode_header_value(value), do: decode_plain_header_value(value)

  defp decode_plain_header_value(value) do
    trimmed = String.trim(value)

    if plain_header_value?(trimmed) do
      {:ok, trimmed}
    else
      {:error, {:routing_mismatch, "invalid plain mcp-name header"}}
    end
  end

  defp plain_header_value?(value) do
    String.valid?(value) and
      Enum.all?(:binary.bin_to_list(value), &(&1 == 0x09 or &1 in 0x20..0x7E))
  end

  # SEP-2243: the `Mcp-Name` target is the method-appropriate field —
  # `params.name` for tool/prompt calls, `params.uri` for resource reads.
  defp routing_target(method, params) when is_map(params) do
    case method do
      "tools/call" -> Map.get(params, "name")
      "prompts/get" -> Map.get(params, "name")
      "resources/read" -> Map.get(params, "uri")
      _ -> nil
    end
  end

  defp routing_target(_method, _params), do: nil

  defp check_custom_routing_headers(
         conn,
         %{"method" => "tools/call", "params" => params},
         tool_schemas,
         identity
       )
       when is_map(params) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    with {:ok, descriptors} <- resolve_tool_descriptors(tool_schemas, name, identity),
         do: validate_custom_descriptors(conn, arguments, descriptors)
  end

  defp check_custom_routing_headers(_conn, _message, _tool_schemas, _identity), do: :ok

  defp validate_custom_descriptors(conn, arguments, descriptors) do
    Enum.reduce_while(descriptors, :ok, fn descriptor, :ok ->
      case check_custom_header(conn, arguments, descriptor) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp check_custom_header(conn, arguments, descriptor) do
    header_name = "mcp-param-#{String.downcase(descriptor.header)}"
    header_value = first_header(conn, header_name)

    case ToolRouting.argument_value(arguments, descriptor) do
      :missing when is_nil(header_value) ->
        :ok

      :missing ->
        routing_mismatch("unexpected #{header_name} header")

      {:ok, _expected} when is_nil(header_value) ->
        routing_mismatch("missing required #{header_name} header")

      {:ok, expected} ->
        with {:ok, decoded} <- decode_header_value(header_value) do
          matching_custom_header(header_name, decoded, expected, descriptor.type)
        end

      {:error, reason} ->
        routing_mismatch("invalid #{header_name} argument: #{reason}")
    end
  end

  defp matching_custom_header(name, header_value, body_value, "integer") do
    with {header_integer, ""} <- Integer.parse(header_value),
         {body_integer, ""} <- Integer.parse(body_value),
         true <- header_integer == body_integer do
      :ok
    else
      _ -> matching_header(name, header_value, body_value)
    end
  end

  defp matching_custom_header(name, header_value, body_value, _type),
    do: matching_header(name, header_value, body_value)

  defp resolve_tool_descriptors(tool_schemas, name, _identity) when is_map(tool_schemas),
    do: {:ok, Map.get(tool_schemas, name, [])}

  defp resolve_tool_descriptors(resolver, name, identity) when is_function(resolver, 2) do
    case resolver.(name, identity) do
      nil -> {:ok, []}
      schema -> ToolRouting.descriptors(schema)
    end
  rescue
    exception -> {:error, {:factory_failed, {:raised, exception, __STACKTRACE__}}}
  end

  defp routing_mismatch(detail), do: {:error, {:routing_mismatch, detail}}

  defp compile_tool_schemas!(resolver) when is_function(resolver, 2), do: resolver

  defp compile_tool_schemas!(schemas) when is_map(schemas) do
    Map.new(schemas, fn {name, schema} ->
      case ToolRouting.descriptors(schema) do
        {:ok, descriptors} ->
          {name, descriptors}

        {:error, reason} ->
          raise ArgumentError,
                "invalid tool schema for #{inspect(name)}: #{inspect(reason)}"
      end
    end)
  end

  defp compile_tool_schemas!(other) do
    raise ArgumentError,
          "tool_schemas must be a map or a 2-arity function, got: #{inspect(other)}"
  end

  # --- Long-lived subscriptions/listen response ---

  defp open_subscription_stream(conn, config, id, params, identity) do
    with :ok <- Dispatch.validate_request(params, config.config),
         :ok <- reject_resumption(conn),
         :ok <- subscription_configuration(config),
         {:ok, requested} <- parse_subscription_filter(params),
         {:ok, honored} <- authorize_subscription(config, id, params, requested, identity),
         {:ok, worker} <-
           SubscriptionWorker.start(
             config.subscription_supervisor,
             config.subscription_registry,
             config.subscription_endpoint,
             id,
             self(),
             requested,
             honored,
             queue_limit: config.subscription_queue_limit
           ) do
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.put_resp_header("cache-control", "no-cache")
        |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
        |> Plug.Conn.send_chunked(200)

      stream_subscription(conn, worker, config.subscription_keepalive_interval)
    else
      {:error, :resumption_unsupported} ->
        send_json_error(
          conn,
          400,
          Error.invalid_request_code(),
          "Invalid request",
          "Last-Event-ID resumption is unsupported",
          id
        )

      {:error, %Error{} = error} ->
        send_json_error(conn, 400, error.code, error.message, inspect(error.data), id)

      {:error, reason} ->
        Logger.error("MCP subscription authorization failed: #{inspect(reason)}")

        send_json_error(
          conn,
          500,
          Error.internal_error_code(),
          "Internal error",
          "subscription authorization failed",
          id
        )
    end
  end

  defp reject_resumption(conn) do
    if Plug.Conn.get_req_header(conn, "last-event-id") == [],
      do: :ok,
      else: {:error, :resumption_unsupported}
  end

  defp subscription_configuration(config) do
    if config.subscription_supervisor && config.subscription_registry,
      do: :ok,
      else: {:error, Error.method_not_found("subscriptions/listen")}
  end

  defp parse_subscription_filter(params) do
    {:ok, ListenParams.from_map(params).notifications}
  rescue
    error in [ArgumentError, KeyError] -> {:error, Error.invalid_params(Exception.message(error))}
  end

  defp authorize_subscription(config, id, params, requested, identity) do
    module = config.config.handler_module

    if function_exported?(module, :handle_listen_subscriptions, 3) do
      with {:ok, collector} <- start_collector(config.collector_start, config) do
        context = %ToolContext{
          request_id: id,
          meta: Map.get(params || %{}, "_meta"),
          identity: identity,
          reply_sink: fn method, callback_params ->
            NotificationCollector.push(collector, method, callback_params)
          end
        }

        try do
          case module.handle_listen_subscriptions(requested, context, config.config.handler_state) do
            {:ok, %SubscriptionFilter{} = honored} -> {:ok, honored}
            {:error, code, message} -> {:error, %Error{code: code, message: message}}
            other -> {:error, {:invalid_subscription_callback_result, other}}
          end
        after
          NotificationCollector.stop(collector)
        end
      end
    else
      {:error, Error.method_not_found("subscriptions/listen")}
    end
  rescue
    exception -> {:error, {:subscription_callback_raised, exception, __STACKTRACE__}}
  end

  defp stream_subscription(conn, worker, keepalive_interval) do
    case SubscriptionWorker.next(worker, keepalive_interval) do
      {:ok, message} ->
        case Plug.Conn.chunk(conn, SSE.encode_message(message)) do
          {:ok, conn} -> stream_subscription(conn, worker, keepalive_interval)
          {:error, _reason} -> close_disconnected_subscription(conn, worker)
        end

      {:error, :timeout} ->
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_subscription(conn, worker, keepalive_interval)
          {:error, _reason} -> close_disconnected_subscription(conn, worker)
        end

      {:error, _reason} ->
        conn
    end
  end

  defp close_disconnected_subscription(conn, worker) do
    if Process.alive?(worker), do: GenServer.stop(worker, :normal)
    conn
  end

  defp validate_subscription_options!(nil, nil, _queue_limit, _keepalive), do: :ok

  defp validate_subscription_options!(supervisor, registry, queue_limit, keepalive) do
    if is_nil(supervisor) or is_nil(registry) do
      raise ArgumentError,
            "subscription_supervisor and subscription_registry must be configured together"
    end

    unless is_integer(queue_limit) and queue_limit > 0 do
      raise ArgumentError, "subscription_queue_limit must be a positive integer"
    end

    unless is_integer(keepalive) and keepalive > 0 do
      raise ArgumentError, "subscription_keepalive_interval must be a positive integer"
    end

    :ok
  end

  # --- Per-request identity resolution (MC-2/Comment B) ---

  defp resolve_identity(fun, conn) when is_function(fun, 1) do
    case fun.(conn) do
      result when is_list(result) ->
        if Keyword.keyword?(result),
          do: {:ok, Keyword.get(result, :identity)},
          else: {:error, {:factory_failed, {:non_keyword_result, result}}}

      other ->
        {:error, {:factory_failed, {:non_keyword_result, other}}}
    end
  rescue
    exception -> {:error, {:factory_failed, {:raised, exception, __STACKTRACE__}}}
  end

  defp resolve_identity(list, _conn) when is_list(list), do: {:ok, Keyword.get(list, :identity)}

  # --- handler_opts validation (fail-fast at mount) ---

  defp validate_handler_opts!(fun) when is_function(fun, 1), do: fun

  defp validate_handler_opts!(list) when is_list(list) do
    if Keyword.keyword?(list) do
      list
    else
      raise ArgumentError,
            "handler_opts must be a keyword list or a 1-arity function " <>
              "(Plug.Conn.t() -> keyword()), got a non-keyword list: #{inspect(list)}"
    end
  end

  defp validate_handler_opts!(other) do
    raise ArgumentError,
          "handler_opts must be a keyword list or a 1-arity function " <>
            "(Plug.Conn.t() -> keyword()), got: #{inspect(other)}"
  end

  # --- AC7: config-time cache-scope footgun warning (once, never per request) ---

  # Fires only when the handler resolves a per-caller identity AND the effective
  # :cache_defaults would stamp ttlMs > 0 with cacheScope "public" onto the
  # cacheable list/read results — i.e. identity-dependent data authorised for a
  # shared cache. Safe configurations (no identity resolution; private scope;
  # or ttlMs 0, the default) emit nothing.
  defp warn_if_public_cache_of_identity_scoped(handler_opts, server_opts) do
    {ttl_ms, cache_scope} = Keyword.get(server_opts, :cache_defaults, {0, "public"})

    if identity_scoped?(handler_opts) and ttl_ms > 0 and cache_scope == "public" do
      Logger.warning(
        "MCP.Transport.StreamableHTTP.Plug: identity-dependent responses may be cached " <>
          "publicly — handler_opts resolves a per-caller identity while :cache_defaults is " <>
          ~s|{#{ttl_ms}, "public"} (ttlMs > 0, public scope). Cacheable list/read results | <>
          "carrying caller-specific data can then be served from a shared cache across " <>
          ~s|principals. Set cache_defaults to a "private" scope (e.g. {#{ttl_ms}, "private"}) | <>
          "— or keep ttlMs at 0 — for identity-dependent results. See MCP.Server.Config.build/2."
      )
    end

    :ok
  end

  # "Configured to resolve identity" = a per-request factory, or a static
  # keyword carrying a non-nil :identity.
  defp identity_scoped?(handler_opts) when is_function(handler_opts, 1), do: true

  defp identity_scoped?(handler_opts) when is_list(handler_opts),
    do: not is_nil(Keyword.get(handler_opts, :identity))

  defp identity_scoped?(_), do: false

  # --- Response shaping ---

  defp send_response(conn, config, response, notifications) do
    status = response_status(response)

    if config.enable_json_response do
      send_json_response(conn, response, status)
    else
      send_sse_response(conn, response, notifications, status)
    end
  end

  defp response_status(%{"error" => %{"code" => code}})
       when code in [-32_022, -32_021, -32_602],
       do: 400

  defp response_status(%{"error" => %{"code" => -32_601}}), do: 404

  defp response_status(_response), do: 200

  defp send_json_response(conn, response, status) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(response))
  end

  defp send_sse_response(conn, response, notifications, status) do
    body =
      (notifications ++ [response])
      |> Enum.map_join(&SSE.encode_message/1)

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.put_resp_header("cache-control", "no-cache")
    |> Plug.Conn.send_resp(status, body)
  end

  defp send_json_error(conn, http_status, code, message, data, id \\ nil) do
    error = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message, "data" => data}
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(http_status, Jason.encode!(error))
  end

  defp method_not_allowed(conn) do
    conn
    |> Plug.Conn.put_resp_header("allow", "GET, POST, DELETE")
    |> Plug.Conn.send_resp(405, "")
  end

  # --- Header / origin helpers ---

  defp first_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp accepts_sse?(conn) do
    conn
    |> Plug.Conn.get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  defp allowed_request?(conn, config) do
    host_allowed?(conn, config.allowed_hosts) and origin_allowed?(conn, config.allowed_origins)
  end

  defp host_allowed?(conn, allowed_hosts) do
    case Plug.Conn.get_req_header(conn, "host") do
      [] -> normalize_host(conn.host) in allowed_hosts
      [value] -> normalize_host(value) in allowed_hosts
      _multiple -> false
    end
  end

  defp origin_allowed?(conn, allowed_origins) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] ->
        true

      [value] ->
        key = origin_key(value, false)

        not is_nil(key) and
          Enum.any?(allowed_origins, fn allowed ->
            origin_matches?(key, origin_key(allowed, true))
          end)

      _multiple ->
        false
    end
  end

  defp origin_key(value, allow_loopback_wildcard?) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and is_integer(port) ->
        host = String.downcase(host)

        normalized_port =
          if allow_loopback_wildcard? and host in @localhost_patterns and
               not explicit_origin_port?(value) do
            :any
          else
            port
          end

        {scheme, host, normalized_port}

      _invalid ->
        nil
    end
  end

  defp origin_matches?({scheme, host, port}, {scheme, host, allowed_port}),
    do: allowed_port == :any or port == allowed_port

  defp origin_matches?(_presented, _allowed), do: false

  defp explicit_origin_port?(origin) when is_binary(origin),
    do: String.match?(origin, ~r/(?:\]|[^:]):\d+$/)

  defp explicit_origin_port?(_authority), do: false

  defp normalize_host(value) do
    value
    |> String.replace(~r/^\[(.*)\](?::\d+)?$/, "\\1")
    |> String.replace(~r/:\d+$/, "")
  end

  defp reject_initialize_session_header(conn) do
    if first_header(conn, "mcp-session-id"),
      do: {:error, :initialize_must_not_include_session_id},
      else: :ok
  end

  defp invalid_request_detail(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp invalid_request_detail({category, _detail}) when is_atom(category),
    do: Atom.to_string(category)

  defp invalid_request_detail(_reason), do: "invalid_request"

  defp validate_positive_integer!(value, name) do
    unless is_integer(value) and value > 0,
      do: raise(ArgumentError, ":#{name} must be a positive integer")
  end

  defp validate_string_list!(value, name) do
    unless is_list(value) and Enum.all?(value, &is_binary/1),
      do: raise(ArgumentError, ":#{name} must be a list of strings")
  end

  defp validate_origin_list!(origins) do
    validate_string_list!(origins, :allowed_origins)

    unless Enum.all?(origins, &(not is_nil(origin_key(&1, true)))) do
      raise ArgumentError, ":allowed_origins must contain only HTTP or HTTPS origins"
    end
  end
end
