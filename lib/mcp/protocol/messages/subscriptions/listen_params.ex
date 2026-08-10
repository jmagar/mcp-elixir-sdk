defmodule MCP.Protocol.Messages.Subscriptions.ListenParams do
  @moduledoc """
  Parameters for `subscriptions/listen`.
  """

  alias MCP.Protocol.Types.SubscriptionFilter

  defstruct [:notifications, :meta]

  @type t :: %__MODULE__{
          notifications: SubscriptionFilter.t(),
          meta: map() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      notifications:
        map
        |> Map.fetch!("notifications")
        |> SubscriptionFilter.from_map(),
      meta: Map.get(map, "_meta")
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{notifications: %SubscriptionFilter{} = notifications} = params) do
    %{"notifications" => SubscriptionFilter.to_map(notifications)}
    |> maybe_put_meta(params.meta)
  end

  defp maybe_put_meta(map, nil), do: map
  defp maybe_put_meta(map, meta) when is_map(meta), do: Map.put(map, "_meta", meta)

  defimpl Jason.Encoder do
    alias MCP.Protocol.Messages.Subscriptions.ListenParams

    def encode(params, opts) do
      params
      |> ListenParams.to_map()
      |> Jason.Encode.map(opts)
    end
  end
end
