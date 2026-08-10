defmodule MCP.Protocol.Capabilities.ResourceCapabilities do
  @moduledoc """
  Server capability for resources.
  """

  defstruct [:subscribe, :list_changed]

  @type t :: %__MODULE__{
          subscribe: boolean() | nil,
          list_changed: boolean() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      subscribe: Map.get(map, "subscribe"),
      list_changed: Map.get(map, "listChanged")
    }
  end

  defimpl Jason.Encoder, for: __MODULE__ do
    def encode(struct, opts) do
      struct
      |> Map.from_struct()
      |> Enum.reduce(%{}, fn
        {_key, nil}, acc -> acc
        {:list_changed, val}, acc -> Map.put(acc, :listChanged, val)
        {key, val}, acc -> Map.put(acc, key, val)
      end)
      |> Jason.Encode.map(opts)
    end
  end
end
