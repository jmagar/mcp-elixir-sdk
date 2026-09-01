defmodule MCP.Apps.Bridge do
  @moduledoc """
  Pure codecs and lifecycle validation for the stable View/host bridge.

  The module does not execute effects or deliver browser messages.

  `ui/open-link` accepts absolute HTTPS URLs by default. Embedding hosts may
  explicitly add schemes with `:open_link_schemes`, but successful decoding
  validates only the wire policy; it does not grant user consent or authorize
  the navigation effect.
  """

  alias MCP.Apps.{Limits, Validator}

  @view_requests ~w(ui/initialize ui/open-link ui/message ui/request-display-mode ui/update-model-context)
  @view_notifications ~w(ui/notifications/initialized ui/notifications/size-changed)
  @host_notifications ~w(ui/notifications/tool-input-partial ui/notifications/tool-input ui/notifications/tool-result ui/notifications/tool-cancelled ui/notifications/host-context-changed)
  @host_requests ~w(ui/resource-teardown)
  @sandbox_notifications ~w(ui/notifications/sandbox-proxy-ready ui/notifications/sandbox-resource-ready)
  @proxy_requests ~w(tools/call resources/read ping)
  @flexible_notifications ~w(ui/notifications/initialized ui/notifications/host-context-changed notifications/message)
  @methods @view_requests ++
             @view_notifications ++
             @host_notifications ++
             @host_requests ++
             @sandbox_notifications ++ @proxy_requests ++ ~w(notifications/message)

  defstruct phase: :new, complete_input?: false, terminal?: false

  @type t :: %__MODULE__{}

  @spec decode(binary() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def decode(message, opts \\ [])

  def decode(json, opts) when is_binary(json) do
    limits = Limits.new(Keyword.get(opts, :limits, []))

    if byte_size(json) > limits.max_message_bytes do
      {:error, :message_too_large}
    else
      case Jason.decode(json) do
        {:ok, message} -> decode(message, opts)
        {:error, _reason} -> {:error, :invalid_json}
      end
    end
  end

  def decode(%{} = message, opts) do
    limits = Limits.new(Keyword.get(opts, :limits, []))

    with :ok <- Validator.validate_json(message, opts),
         {:ok, json} <- Jason.encode(message),
         true <- byte_size(json) <= limits.max_message_bytes or {:error, :message_too_large},
         :ok <- validate_envelope(message, opts) do
      {:ok, message}
    else
      {:error, _reason} = error -> error
    end
  end

  def decode(_message, _opts), do: {:error, :invalid_bridge_message}

  @spec encode(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def encode(message, opts \\ []) do
    limits = Limits.new(Keyword.get(opts, :limits, []))

    with {:ok, validated} <- decode(message, opts),
         {:ok, json} <- Jason.encode(validated),
         true <- byte_size(json) <= limits.max_message_bytes or {:error, :message_too_large} do
      {:ok, json}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec transition(t(), map()) :: {:ok, t(), [term()]} | {:error, term()}
  def transition(%__MODULE__{phase: :new} = state, %{"method" => "ui/initialize"}),
    do: {:ok, %{state | phase: :initializing}, [:reply_initialize]}

  def transition(%__MODULE__{phase: :initializing} = state, %{
        "method" => "ui/notifications/initialized"
      }),
      do: {:ok, %{state | phase: :ready}, []}

  def transition(%__MODULE__{phase: :ready, complete_input?: false, terminal?: false} = state, %{
        "method" => "ui/notifications/tool-input-partial"
      }),
      do: {:ok, state, []}

  def transition(%__MODULE__{phase: :ready, complete_input?: false, terminal?: false} = state, %{
        "method" => "ui/notifications/tool-input"
      }),
      do: {:ok, %{state | complete_input?: true}, []}

  def transition(%__MODULE__{phase: :ready, complete_input?: true, terminal?: false} = state, %{
        "method" => "ui/notifications/tool-result"
      }),
      do: {:ok, %{state | terminal?: true}, []}

  def transition(%__MODULE__{phase: :ready, terminal?: false} = state, %{
        "method" => "ui/notifications/tool-cancelled"
      }),
      do: {:ok, %{state | terminal?: true}, []}

  def transition(%__MODULE__{phase: :ready} = state, %{"method" => "ui/resource-teardown"}),
    do: {:ok, %{state | phase: :tearing_down}, [:reply_teardown]}

  def transition(_state, _message), do: {:error, :invalid_lifecycle_transition}

  defp validate_envelope(%{"jsonrpc" => "2.0", "method" => method} = message, opts)
       when method in @methods do
    request? = Map.has_key?(message, "id")

    cond do
      Map.has_key?(message, "result") or Map.has_key?(message, "error") ->
        {:error, :ambiguous_bridge_envelope}

      request? and not valid_id?(message["id"]) ->
        {:error, :invalid_bridge_id}

      method == "ui/initialize" ->
        validate_initialize(message, request?)

      true ->
        validate_method_envelope(message, method, request?, opts)
    end
  end

  defp validate_envelope(%{"jsonrpc" => "2.0", "id" => id} = message, _opts) do
    success? = Map.has_key?(message, "result")
    error? = Map.has_key?(message, "error")

    cond do
      not valid_id?(id) -> {:error, :invalid_bridge_id}
      Map.has_key?(message, "method") -> {:error, :ambiguous_bridge_envelope}
      success? == error? -> {:error, :invalid_bridge_response}
      error? and not valid_error?(message["error"]) -> {:error, :invalid_bridge_error}
      true -> :ok
    end
  end

  defp validate_envelope(_message, _opts), do: {:error, :invalid_bridge_message}

  defp validate_method_envelope(message, method, request?, opts) do
    request_methods = @view_requests ++ @host_requests ++ @proxy_requests

    cond do
      Map.has_key?(message, "result") or Map.has_key?(message, "error") ->
        {:error, :ambiguous_bridge_envelope}

      request? and method not in request_methods ->
        {:error, :unexpected_request_id}

      not request? and method in request_methods ->
        {:error, :missing_request_id}

      not is_map(Map.get(message, "params", %{})) ->
        {:error, :invalid_bridge_params}

      true ->
        validate_params(method, Map.get(message, "params", %{}), opts)
    end
  end

  defp validate_initialize(%{"params" => params}, true) when is_map(params) do
    if params["protocolVersion"] == MCP.Apps.protocol_version() and
         is_map(params["appInfo"]) and is_map(params["appCapabilities"]),
       do: :ok,
       else: {:error, :invalid_initialize_params}
  end

  defp validate_initialize(_message, _request?), do: {:error, :invalid_initialize_request}

  defp validate_params("ui/open-link", %{"url" => url}, opts) when is_binary(url) do
    parsed = URI.parse(url)
    allowed_schemes = Keyword.get(opts, :open_link_schemes, ["https"])

    if valid_open_link?(parsed, url, allowed_schemes),
      do: :ok,
      else: {:error, :invalid_bridge_params}
  end

  defp validate_params("ui/message", %{"role" => "user", "content" => content}, _opts)
       when is_map(content),
       do: :ok

  defp validate_params("ui/request-display-mode", %{"mode" => mode}, _opts)
       when mode in ["inline", "fullscreen", "pip"],
       do: :ok

  defp validate_params("ui/update-model-context", params, _opts) do
    content = Map.get(params, "content")
    structured = Map.get(params, "structuredContent")

    if (is_nil(content) or is_list(content)) and (is_nil(structured) or is_map(structured)),
      do: :ok,
      else: {:error, :invalid_bridge_params}
  end

  defp validate_params(method, %{"arguments" => arguments}, _opts)
       when method in ["ui/notifications/tool-input", "ui/notifications/tool-input-partial"] and
              is_map(arguments),
       do: :ok

  defp validate_params("ui/notifications/tool-result", %{"content" => content}, _opts)
       when is_list(content),
       do: :ok

  defp validate_params("ui/notifications/tool-cancelled", params, _opts) do
    if optional_binary?(params, "reason"), do: :ok, else: {:error, :invalid_bridge_params}
  end

  defp validate_params("ui/notifications/size-changed", params, _opts) do
    if Enum.any?(["width", "height"], &Map.has_key?(params, &1)) and
         optional_nonnegative_number?(params, "width") and
         optional_nonnegative_number?(params, "height"),
       do: :ok,
       else: {:error, :invalid_bridge_params}
  end

  defp validate_params("ui/notifications/sandbox-proxy-ready", params, _opts)
       when map_size(params) == 0,
       do: :ok

  defp validate_params(
         "ui/notifications/sandbox-resource-ready",
         %{"html" => html} = params,
         opts
       )
       when is_binary(html) do
    limits = Limits.new(Keyword.get(opts, :limits, []))

    with true <- byte_size(html) <= limits.max_resource_bytes,
         true <- optional_binary?(params, "sandbox"),
         {:ok, _metadata} <-
           Validator.resource_metadata(
             %{"ui" => Map.take(params, ["csp", "permissions"])},
             opts
           ) do
      :ok
    else
      _invalid -> {:error, :invalid_bridge_params}
    end
  end

  defp validate_params("ui/resource-teardown", params, _opts) do
    if optional_binary?(params, "reason"), do: :ok, else: {:error, :invalid_bridge_params}
  end

  defp validate_params("tools/call", %{"name" => name} = params, _opts) when is_binary(name) do
    arguments = Map.get(params, "arguments", %{})
    if is_map(arguments), do: :ok, else: {:error, :invalid_bridge_params}
  end

  defp validate_params("resources/read", %{"uri" => uri}, _opts) when is_binary(uri), do: :ok
  defp validate_params("ping", params, _opts) when map_size(params) == 0, do: :ok

  defp validate_params(method, params, _opts)
       when method in @flexible_notifications and is_map(params),
       do: :ok

  defp validate_params(_method, _params, _opts), do: {:error, :invalid_bridge_params}

  defp valid_open_link?(parsed, url, allowed_schemes)
       when is_list(allowed_schemes) do
    is_binary(parsed.scheme) and
      String.downcase(parsed.scheme) in allowed_schemes and
      is_binary(parsed.host) and parsed.host != "" and
      is_nil(parsed.userinfo) and
      not String.match?(url, ~r/[\x00-\x1F\x7F]/)
  end

  defp valid_open_link?(_parsed, _url, _allowed_schemes), do: false

  defp optional_binary?(params, key),
    do: not Map.has_key?(params, key) or is_binary(params[key])

  defp optional_nonnegative_number?(params, key),
    do: not Map.has_key?(params, key) or (is_number(params[key]) and params[key] >= 0)

  defp valid_error?(%{"code" => code, "message" => message}),
    do: is_integer(code) and is_binary(message)

  defp valid_error?(_error), do: false
  defp valid_id?(id), do: is_integer(id) or (is_binary(id) and id != "")
end
