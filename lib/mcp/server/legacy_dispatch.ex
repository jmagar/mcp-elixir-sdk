defmodule MCP.Server.LegacyDispatch do
  @moduledoc """
  Version-isolated dispatcher for the stateful MCP 2025-11-25 protocol era.

  The connection/session owner enforces the initialize state machine. This
  module adapts legacy request envelopes to the immutable, context-bearing
  handler contract used by the 2026 runtime and removes 2026-only result
  members from responses sent to older peers.
  """

  alias MCP.Protocol.Capabilities.{LoggingCapabilities, ResourceCapabilities}
  alias MCP.Protocol.Messages.{Initialize, Request}
  alias MCP.Server.{Dispatch, ToolContext}

  require Logger

  @protocol_version "2025-11-25"
  @stateless_meta_keys [
    "io.modelcontextprotocol/protocolVersion",
    "io.modelcontextprotocol/clientInfo",
    "io.modelcontextprotocol/clientCapabilities"
  ]
  @stateless_result_keys ["resultType", "ttlMs", "cacheScope"]

  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @spec initialize(Request.t(), map()) :: {:ok, map(), Initialize.Params.t()} | {:error, map()}
  def initialize(%Request{id: id, params: params}, config) do
    initialize = Initialize.Params.from_map(params || %{})

    if initialize.protocol_version == @protocol_version do
      result =
        Initialize.Result.to_map(%Initialize.Result{
          protocol_version: @protocol_version,
          capabilities: legacy_capabilities(config),
          server_info: config.server_info,
          instructions: config.instructions
        })

      {:ok, success(id, result), initialize}
    else
      {:error,
       error(id, -32_022, "Unsupported protocol version", %{
         "requested" => initialize.protocol_version,
         "supported" => [@protocol_version, Dispatch.protocol_version()]
       })}
    end
  rescue
    exception in [ArgumentError, KeyError, FunctionClauseError] ->
      {:error, error(id, -32_602, "Invalid params", Exception.message(exception))}
  end

  @spec dispatch(Request.t(), ToolContext.t(), map()) ::
          {:reply, map()} | {:input_required, map(), term()}
  def dispatch(%Request{id: id, method: "ping", params: params}, _ctx, _config) do
    with {:ok, params} <- generic_params_object(params),
         {:ok, _meta} <- legacy_meta(params) do
      {:reply, success(id, %{})}
    else
      {:error, reason} -> {:reply, error(id, -32_602, "Invalid params", reason)}
    end
  end

  def dispatch(
        %Request{id: id, method: "resources/subscribe", params: params},
        context,
        config
      ) do
    with {:ok, params} <- params_object(params),
         {:ok, _meta} <- legacy_meta(params),
         {:ok, uri} <- required_nonempty_string(params, "uri") do
      legacy_callback(
        id,
        :handle_subscribe,
        [uri],
        context,
        config
      )
    else
      {:error, reason} -> {:reply, error(id, -32_602, "Invalid params", reason)}
    end
  end

  def dispatch(
        %Request{id: id, method: "resources/unsubscribe", params: params},
        context,
        config
      ) do
    with {:ok, params} <- params_object(params),
         {:ok, _meta} <- legacy_meta(params),
         {:ok, uri} <- required_nonempty_string(params, "uri") do
      legacy_callback(
        id,
        :handle_unsubscribe,
        [uri],
        context,
        config
      )
    else
      {:error, reason} -> {:reply, error(id, -32_602, "Invalid params", reason)}
    end
  end

  def dispatch(%Request{id: id, method: "logging/setLevel", params: params}, context, config) do
    with {:ok, params} <- params_object(params),
         {:ok, _meta} <- legacy_meta(params),
         {:ok, level} <- logging_level(params) do
      legacy_callback(
        id,
        :handle_set_log_level,
        [level],
        context,
        config
      )
    else
      {:error, reason} -> {:reply, error(id, -32_602, "Invalid params", reason)}
    end
  end

  def dispatch(%Request{} = request, %ToolContext{} = context, config) do
    with {:ok, params} <- generic_params_object(request.params),
         {:ok, meta} <- legacy_meta(params) do
      dispatch_adapted(request, params, meta, context, config)
    else
      {:error, reason} -> {:reply, error(request.id, -32_602, "Invalid params", reason)}
    end
  end

  defp dispatch_adapted(request, params, meta, context, config) do
    meta = Map.drop(meta, @stateless_meta_keys)

    adapted_params =
      if meta == %{} do
        Map.delete(params, "_meta")
      else
        Map.put(params, "_meta", meta)
      end

    stateless_meta = %{
      "io.modelcontextprotocol/protocolVersion" => Dispatch.protocol_version(),
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    adapted = %{
      request
      | params: Map.put(adapted_params, "_meta", Map.merge(meta, stateless_meta))
    }

    # The injected 2026 metadata is strictly an internal adapter detail. A
    # legacy handler must observe only metadata the legacy peer actually sent.
    context = %{context | meta: meta}

    case Dispatch.dispatch(adapted, context, config) do
      {:reply,
       %{
         "result" =>
           %{
             "resultType" => "input_required",
             "inputRequests" => requests
           } = result
       }} ->
        {:input_required, requests, Map.get(result, "requestState")}

      {:reply, %{"result" => result} = response} when is_map(result) ->
        {:reply, %{response | "result" => Map.drop(result, @stateless_result_keys)}}

      {:reply, response} ->
        {:reply, response}
    end
  end

  defp success(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp legacy_capabilities(config) do
    callbacks = config.handler_module.__info__(:functions)

    subscribe? =
      {:handle_subscribe, 3} in callbacks and {:handle_unsubscribe, 3} in callbacks

    resources =
      case config.capabilities.resources do
        nil when subscribe? -> %ResourceCapabilities{subscribe: true}
        nil -> nil
        resources -> %{resources | subscribe: if(subscribe?, do: true)}
      end

    %{
      config.capabilities
      | resources: resources,
        logging: if({:handle_set_log_level, 3} in callbacks, do: %LoggingCapabilities{})
    }
  end

  defp params_object(params) when is_map(params), do: {:ok, params}
  defp params_object(_params), do: {:error, "params must be an object"}

  defp generic_params_object(nil), do: {:ok, %{}}
  defp generic_params_object(params), do: params_object(params)

  defp legacy_meta(params) do
    case Map.get(params, "_meta", %{}) do
      meta when is_map(meta) -> {:ok, meta}
      _invalid -> {:error, "_meta must be an object"}
    end
  end

  defp required_nonempty_string(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, "#{key} must be a non-empty string"}
      :error -> {:error, "#{key} is required"}
    end
  end

  defp logging_level(params) do
    with {:ok, level} <- required_nonempty_string(params, "level"),
         true <- level in ~w(debug info notice warning error critical alert emergency) do
      {:ok, level}
    else
      false -> {:error, "level is not a valid logging level"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_callback(id, callback, arguments, context, config) do
    module = config.handler_module
    callback_arguments = arguments ++ [context, config.handler_state]

    if function_exported?(module, callback, length(callback_arguments)) do
      try do
        case apply(module, callback, callback_arguments) do
          :ok -> {:reply, success(id, %{})}
          {:ok} -> {:reply, success(id, %{})}
          {:error, code, message} -> {:reply, error(id, code, message, nil)}
          _invalid -> {:reply, error(id, -32_603, "Invalid handler result", nil)}
        end
      rescue
        exception ->
          log_callback_failure(module, callback, id, :error, exception, __STACKTRACE__)
          {:reply, error(id, -32_603, "Handler callback failed", nil)}
      catch
        kind, reason ->
          log_callback_failure(module, callback, id, kind, reason, __STACKTRACE__)
          {:reply, error(id, -32_603, "Handler callback failed", nil)}
      end
    else
      {:reply, error(id, -32_601, "Method not found: #{callback}", nil)}
    end
  end

  defp log_callback_failure(module, callback, id, kind, reason, stacktrace) do
    Logger.error(
      "MCP legacy handler callback failed module=#{inspect(module)} callback=#{callback} " <>
        "request_id=#{inspect(id)} " <> Exception.format(kind, reason, stacktrace)
    )
  end

  defp error(id, code, message, data) do
    body = %{"code" => code, "message" => message}
    body = if is_nil(data), do: body, else: Map.put(body, "data", data)
    %{"jsonrpc" => "2.0", "id" => id, "error" => body}
  end
end
