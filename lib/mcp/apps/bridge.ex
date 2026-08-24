defmodule MCP.Apps.Bridge do
  @moduledoc """
  Pure codecs and lifecycle validation for the stable View/host bridge.

  The module does not execute effects or deliver browser messages.
  """

  alias MCP.Apps.{Limits, Validator}

  @view_requests ~w(ui/initialize ui/open-link ui/message ui/request-display-mode ui/update-model-context)
  @view_notifications ~w(ui/notifications/initialized ui/notifications/size-changed)
  @host_notifications ~w(ui/notifications/tool-input-partial ui/notifications/tool-input ui/notifications/tool-result ui/notifications/tool-cancelled ui/notifications/host-context-changed)
  @host_requests ~w(ui/resource-teardown)
  @sandbox_notifications ~w(ui/notifications/sandbox-proxy-ready ui/notifications/sandbox-resource-ready)
  @methods @view_requests ++
             @view_notifications ++
             @host_notifications ++
             @host_requests ++
             @sandbox_notifications ++ ~w(tools/call resources/read notifications/message ping)

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
         :ok <- validate_envelope(message) do
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

  defp validate_envelope(%{"jsonrpc" => "2.0", "method" => method} = message)
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
        validate_method_envelope(message, method, request?)
    end
  end

  defp validate_envelope(%{"jsonrpc" => "2.0", "id" => id} = message) do
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

  defp validate_envelope(_message), do: {:error, :invalid_bridge_message}

  defp validate_method_envelope(message, method, request?) do
    request_methods = @view_requests ++ @host_requests

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
        :ok
    end
  end

  defp validate_initialize(%{"params" => params}, true) when is_map(params) do
    if params["protocolVersion"] == MCP.Apps.protocol_version() and
         is_map(params["appInfo"]) and is_map(params["appCapabilities"]),
       do: :ok,
       else: {:error, :invalid_initialize_params}
  end

  defp validate_initialize(_message, _request?), do: {:error, :invalid_initialize_request}

  defp valid_error?(%{"code" => code, "message" => message}),
    do: is_integer(code) and is_binary(message)

  defp valid_error?(_error), do: false
  defp valid_id?(id), do: is_integer(id) or (is_binary(id) and id != "")
end
