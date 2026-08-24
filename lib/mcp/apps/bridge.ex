defmodule MCP.Apps.Bridge do
  @moduledoc """
  Pure codecs and lifecycle validation for the stable View/host bridge.

  The module does not execute effects or deliver browser messages.
  """

  alias MCP.Apps.Limits

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

  defstruct phase: :new, complete_input?: false, terminal?: false, correlations: MapSet.new()

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

  def decode(%{"jsonrpc" => "2.0", "method" => method} = message, _opts) when method in @methods,
    do: {:ok, message}

  def decode(%{"jsonrpc" => "2.0", "id" => id} = message, _opts) when not is_nil(id),
    do: {:ok, message}

  def decode(_message, _opts), do: {:error, :invalid_bridge_message}

  @spec encode(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def encode(message, opts \\ []) do
    limits = Limits.new(Keyword.get(opts, :limits, []))

    with {:ok, validated} <- decode(message, opts),
         {:ok, json} <- Jason.encode(validated),
         true <- byte_size(json) <= limits.max_message_bytes or {:error, :message_too_large} do
      {:ok, json}
    else
      false -> {:error, :message_too_large}
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

  def transition(%__MODULE__{phase: :ready, complete_input?: false} = state, %{
        "method" => "ui/notifications/tool-input-partial"
      }),
      do: {:ok, state, []}

  def transition(%__MODULE__{phase: :ready, complete_input?: false} = state, %{
        "method" => "ui/notifications/tool-input"
      }),
      do: {:ok, %{state | complete_input?: true}, []}

  def transition(%__MODULE__{phase: :ready, terminal?: false} = state, %{"method" => method})
      when method in ["ui/notifications/tool-result", "ui/notifications/tool-cancelled"],
      do: {:ok, %{state | terminal?: true}, []}

  def transition(%__MODULE__{phase: :ready} = state, %{"method" => "ui/resource-teardown"}),
    do: {:ok, %{state | phase: :tearing_down}, [:reply_teardown]}

  def transition(_state, _message), do: {:error, :invalid_lifecycle_transition}
end
