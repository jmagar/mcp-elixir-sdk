defmodule MCP.Server.Dispatch do
  @moduledoc """
  Stateless per-request dispatch for the MCP 2026-07-28 protocol core.

  This is the stateless successor to the per-session `MCP.Server` GenServer: a
  **pure, per-request** entry point that a transport calls once per decoded
  message. There is no `initialize` handshake, no `:ready` gate, and no
  session — every request stands alone (SEP-2575 / SEP-2567).

  ## Contract (fixed here for MES-9)

      dispatch(message, context, config)
        :: {:reply, response_map}
         | :noreply

  * `message` — a decoded `MCP.Protocol.Messages.Request` or `Notification`.
  * `context` — the per-request `MCP.Server.ToolContext` carrying `:identity`,
    already populated by the transport pipeline (HTTP: per request from `conn`;
    stdio: once at launch — PO Comment B). **The dispatch never derives identity
    from the message body** — see MC-2/MC-4.
  * `config` — `%{handler_module, handler_state, server_info, capabilities,
    instructions, protocol_version}`.

  The context is passed to **every identity-capable handler callback** (MC-1).
  MC-1 is **strict** (PO Ruling 4): the context-bearing callback arity is
  *required* for every identity-capable family — there is **no legacy
  no-context fallback**. A handler that does not implement the required context
  arity is a contract error, surfaced as method-not-found; the legacy arity is
  **never** invoked.

  > #### Provenance {: .info}
  > This paragraph corrects doc drift: the MES-8 F3 correction removed the
  > legacy-arity fallback from `call/6`, but the moduledoc still described it
  > (MES-9 review F3). Doc statements about removed behaviour are claims too.

  Removed methods (`initialize`, `ping`, `logging/setLevel`, and the legacy
  resource subscription methods) return method-not-found.
  """

  alias MCP.Protocol.Error
  alias MCP.Protocol.Messages.{Discover, MRTR, Notification, Request, Tools}
  alias MCP.Protocol.Meta
  alias MCP.Protocol.Revision
  alias MCP.Server.ToolContext

  require Logger

  # Conservative caching policy default (SEP-2549): no-store (ttlMs 0), public
  # scope. `resultType` "complete" is the Result base requirement (schema.ts:658).
  @default_cache_defaults {0, "public"}

  @stateless_protocol_version Revision.preferred()

  @doc "The protocol version this stateless core targets."
  def protocol_version, do: @stateless_protocol_version

  @type config :: %{optional(atom()) => term()}
  @type result :: {:reply, map()} | :noreply

  @spec dispatch(Request.t() | Notification.t(), ToolContext.t(), config()) :: result()
  def dispatch(%Request{id: id, method: method, params: params}, %ToolContext{} = ctx, config) do
    handle_request(method, id, params, ctx, config)
  end

  def dispatch(%Notification{method: method, params: params}, %ToolContext{} = ctx, config) do
    handle_notification(method, params, ctx, config)
  end

  @doc false
  @spec validate_request(map() | nil, config()) :: :ok | {:error, Error.t()}
  def validate_request(params, config) do
    meta = Meta.from_params(params)

    with :ok <- Meta.validate_required(meta),
         :ok <- Meta.validate_protocol_version(meta, target_version(config)) do
      :ok
    else
      {:error, {:unsupported, _version}} ->
        {:error, unsupported_version_error(meta, config)}

      {:error, :missing} ->
        {:error, unsupported_version_error(meta, config)}

      {:error, reason} ->
        {:error, Error.invalid_params(Atom.to_string(reason))}
    end
  end

  # --- Removed methods: stateless behaviour, no legacy path ---

  defp handle_request(method, id, _params, _ctx, config)
       when method in [
              "initialize",
              "ping",
              "logging/setLevel",
              "resources/subscribe",
              "resources/unsubscribe"
            ] do
    reply(id, Error.method_not_found(method), config)
  end

  # --- Required metadata and per-request version gate ---

  defp handle_request(method, id, params, ctx, config) do
    case validate_request(params, config) do
      :ok ->
        route(method, id, params, ctx, config)

      {:error, %Error{} = error} ->
        reply(id, error, config)
    end
  end

  # --- Routing to identity-capable handler callbacks (context passed to each) ---

  defp route("server/discover", id, _params, _ctx, config) do
    result =
      Discover.Result.to_map(%Discover.Result{
        supported_versions: [target_version(config)],
        capabilities: Map.get(config, :capabilities),
        server_info: Map.get(config, :server_info),
        instructions: Map.get(config, :instructions)
      })

    {:reply, success(id, result)}
  end

  defp route("tools/list", id, params, ctx, config) do
    cursor = get_in_params(params, "cursor")

    call(
      config,
      ctx,
      :handle_list_tools,
      [cursor],
      fn
        {:ok, tools, next_cursor} ->
          cacheable(list_result("tools", tools, next_cursor), config)
      end,
      id
    )
  end

  # tools/call supports MRTR: the per-request context carries any
  # continuation (requestState/inputResponses) parsed from params (SEP-2322),
  # and the handler may return `{:input_required, ...}` to request client input.
  defp route("tools/call", id, params, ctx, config) do
    name = Map.get(params || %{}, "name", "")
    args = Map.get(params || %{}, "arguments", %{})

    case continuation_context(ctx, params) do
      {:ok, ctx} ->
        call(
          config,
          ctx,
          :handle_call_tool,
          [name, args],
          fn
            {:ok, %Tools.CallResult{} = result} ->
              result |> Tools.CallResult.to_map() |> complete()

            {:ok, result} when is_map(result) ->
              complete(result)

            {:ok, content} ->
              complete(%{"content" => content})

            {:ok, content, is_error} ->
              complete(maybe_error(%{"content" => content}, is_error))

            {:input_required, input_requests, request_state} ->
              MRTR.input_required(input_requests, request_state)

            {:error, code, message} ->
              {:error, %Error{code: code, message: message}}

            {:error, code, message, data} ->
              {:error, %Error{code: code, message: message, data: data}}
          end,
          id
        )

      {:error, reason} ->
        reply(id, Error.invalid_params(Atom.to_string(reason)), config)
    end
  end

  defp route("resources/list", id, params, ctx, config) do
    cursor = get_in_params(params, "cursor")

    call(
      config,
      ctx,
      :handle_list_resources,
      [cursor],
      fn
        {:ok, resources, next_cursor} ->
          cacheable(list_result("resources", resources, next_cursor), config)
      end,
      id
    )
  end

  defp route("resources/read", id, params, ctx, config) do
    uri = Map.get(params || %{}, "uri", "")

    case continuation_context(ctx, params) do
      {:ok, ctx} ->
        call(
          config,
          ctx,
          :handle_read_resource,
          [uri],
          fn
            {:ok, contents} ->
              cacheable(%{"contents" => contents}, config)

            {:input_required, input_requests, request_state} ->
              MRTR.input_required(input_requests, request_state)

            {:error, code, message} ->
              {:error, %Error{code: code, message: message}}

            {:error, code, message, data} ->
              {:error, %Error{code: code, message: message, data: data}}
          end,
          id
        )

      {:error, reason} ->
        reply(id, Error.invalid_params(Atom.to_string(reason)), config)
    end
  end

  defp route("resources/templates/list", id, params, ctx, config) do
    cursor = get_in_params(params, "cursor")

    call(
      config,
      ctx,
      :handle_list_resource_templates,
      [cursor],
      fn
        {:ok, templates, next_cursor} ->
          cacheable(list_result("resourceTemplates", templates, next_cursor), config)
      end,
      id
    )
  end

  defp route("prompts/list", id, params, ctx, config) do
    cursor = get_in_params(params, "cursor")

    call(
      config,
      ctx,
      :handle_list_prompts,
      [cursor],
      fn
        {:ok, prompts, next_cursor} ->
          cacheable(list_result("prompts", prompts, next_cursor), config)
      end,
      id
    )
  end

  defp route("prompts/get", id, params, ctx, config) do
    name = Map.get(params || %{}, "name", "")
    args = Map.get(params || %{}, "arguments")

    case continuation_context(ctx, params) do
      {:ok, ctx} ->
        call(
          config,
          ctx,
          :handle_get_prompt,
          [name, args],
          fn
            {:ok, result} ->
              complete(result)

            {:input_required, input_requests, request_state} ->
              MRTR.input_required(input_requests, request_state)

            {:error, code, message} ->
              {:error, %Error{code: code, message: message}}

            {:error, code, message, data} ->
              {:error, %Error{code: code, message: message, data: data}}
          end,
          id
        )

      {:error, reason} ->
        reply(id, Error.invalid_params(Atom.to_string(reason)), config)
    end
  end

  defp route("completion/complete", id, params, ctx, config) do
    ref = Map.get(params || %{}, "ref", %{})
    argument = Map.get(params || %{}, "argument", %{})

    call(
      config,
      ctx,
      :handle_complete,
      [ref, argument],
      fn
        {:ok, completion} -> complete(%{"completion" => completion})
      end,
      id
    )
  end

  defp route(method, id, _params, _ctx, config) do
    reply(id, Error.method_not_found(method), config)
  end

  # --- Notifications (SDK-internal; never dispatched to consumer callbacks) ---

  defp handle_notification("notifications/initialized", _params, _ctx, _config) do
    # Removed in the stateless core (no handshake). Tolerated as a no-op.
    :noreply
  end

  defp handle_notification(_method, _params, _ctx, _config) do
    :noreply
  end

  # --- Callback invocation: prefer the context-bearing arity (MC-1) ---

  # Calls the **context-bearing** callback `name` (leading_args ++ [context, state]).
  #
  # MC-1 is strict (PO Ruling 4): the context arity is REQUIRED for every
  # identity-capable family — there is NO legacy no-context fallback (that would
  # be uncharted dual-era support, contra PO ruling 2). A handler that does not
  # implement the required context arity is a contract error, surfaced as
  # method-not-found rather than silently invoked without a context.
  defp call(config, ctx, name, leading_args, shape, id) do
    mod = config.handler_module
    state = config.handler_state
    ctx_args = leading_args ++ [ctx, state]

    if function_exported?(mod, name, length(ctx_args)) do
      try do
        apply(mod, name, ctx_args) |> finish(shape, id, config)
      rescue
        exception -> handler_failure(name, id, config, :error, exception, __STACKTRACE__)
      catch
        kind, reason -> handler_failure(name, id, config, kind, reason, __STACKTRACE__)
      end
    else
      reply(id, Error.method_not_found(Atom.to_string(name)), config)
    end
  end

  defp handler_failure(name, id, config, kind, reason, stacktrace) do
    Logger.error(
      "MCP server handler callback failed callback=#{name} " <>
        Exception.format(kind, reason, stacktrace)
    )

    reply(id, Error.internal_error("handler callback failed"), config)
  end

  defp finish(callback_return, shape, id, _config) do
    case shape.(callback_return) do
      {:error, %Error{} = e} -> {:reply, error_response(id, e)}
      result_map -> {:reply, success(id, result_map)}
    end
  end

  # --- Result/response helpers ---

  defp list_result(key, items, next_cursor) do
    base = %{key => items}
    if next_cursor, do: Map.put(base, "nextCursor", next_cursor), else: base
  end

  # Every result carries `resultType` (Result base, schema.ts:658).
  defp complete(map), do: Map.put(map, "resultType", "complete")

  # CacheableResult (list/read) additionally carries ttlMs/cacheScope
  # (schema.ts:969). Policy default is no-store; a config `:cache_defaults`
  # {ttl_ms, scope} overrides.
  defp cacheable(map, config) do
    {ttl_ms, cache_scope} = Map.get(config, :cache_defaults, @default_cache_defaults)

    map
    |> complete()
    |> Map.put("ttlMs", ttl_ms)
    |> Map.put("cacheScope", cache_scope)
  end

  defp maybe_error(result, true), do: Map.put(result, "isError", true)
  defp maybe_error(result, _), do: result

  defp reply(id, %Error{} = error, _config) do
    {:reply, error_response(id, error)}
  end

  defp success(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, %Error{} = e) do
    error = %{"code" => e.code, "message" => e.message}
    error = if e.data, do: Map.put(error, "data", e.data), else: error
    %{"jsonrpc" => "2.0", "id" => id, "error" => error}
  end

  defp target_version(config), do: Map.get(config, :protocol_version, @stateless_protocol_version)

  defp unsupported_version_error(meta, config) do
    Error.unsupported_protocol_version(%{
      "requested" => meta.protocol_version,
      "supported" => [target_version(config)]
    })
  end

  defp continuation_context(ctx, params) do
    case MRTR.continuation_from_params(params) do
      {:error, reason} -> {:error, reason}
      input -> {:ok, %{ctx | input: input}}
    end
  end

  defp get_in_params(nil, _key), do: nil
  defp get_in_params(params, key), do: Map.get(params, key)
end
