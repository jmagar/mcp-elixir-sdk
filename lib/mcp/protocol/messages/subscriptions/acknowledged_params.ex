defmodule MCP.Protocol.Messages.Subscriptions.AcknowledgedParams do
  @moduledoc """
  Parameters for `notifications/subscriptions/acknowledged`.
  """

  alias MCP.Protocol.Types.SubscriptionFilter

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  defstruct [:notifications, :meta]

  @type t :: %__MODULE__{
          notifications: SubscriptionFilter.t(),
          meta: map()
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    meta = map |> Map.fetch!("_meta") |> validate_meta!()

    %__MODULE__{
      notifications:
        map
        |> Map.fetch!("notifications")
        |> SubscriptionFilter.from_map(),
      meta: meta
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{notifications: %SubscriptionFilter{} = notifications} = params) do
    %{
      "notifications" => SubscriptionFilter.to_map(notifications),
      "_meta" => validate_meta!(params.meta)
    }
  end

  defp validate_meta!(meta) when is_map(meta) do
    case Map.get(meta, @subscription_id_key) do
      id when is_binary(id) or is_integer(id) -> meta
      _ -> raise ArgumentError, "_meta must contain a string or integer subscription ID"
    end
  end

  defp validate_meta!(_meta) do
    raise ArgumentError, "_meta must contain a string or integer subscription ID"
  end

  defimpl Jason.Encoder do
    alias MCP.Protocol.Messages.Subscriptions.AcknowledgedParams

    def encode(params, opts) do
      params
      |> AcknowledgedParams.to_map()
      |> Jason.Encode.map(opts)
    end
  end
end
