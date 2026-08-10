defmodule MCP.Protocol.Types.Root do
  @moduledoc """
  A filesystem root that a client exposes to servers.
  """

  defstruct [:uri, :name, :meta]

  @type t :: %__MODULE__{
          uri: String.t(),
          name: String.t() | nil,
          meta: map() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      uri: Map.fetch!(map, "uri"),
      name: Map.get(map, "name"),
      meta: Map.get(map, "_meta")
    }
  end

  defimpl Jason.Encoder, for: __MODULE__ do
    def encode(struct, opts) do
      struct
      |> Map.from_struct()
      |> Enum.reduce(%{}, fn
        {_key, nil}, acc -> acc
        {:meta, val}, acc -> Map.put(acc, :_meta, val)
        {key, val}, acc -> Map.put(acc, key, val)
      end)
      |> Jason.Encode.map(opts)
    end
  end
end
