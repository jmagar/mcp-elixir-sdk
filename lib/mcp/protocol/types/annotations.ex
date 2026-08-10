defmodule MCP.Protocol.Types.Annotations do
  @moduledoc """
  Content annotations describing audience, priority, and modification time.
  """

  defstruct [:audience, :priority, :last_modified]

  @type t :: %__MODULE__{
          audience: [String.t()] | nil,
          priority: float() | nil,
          last_modified: String.t() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      audience: Map.get(map, "audience"),
      priority: Map.get(map, "priority"),
      last_modified: Map.get(map, "lastModified")
    }
  end

  defimpl Jason.Encoder, for: __MODULE__ do
    def encode(struct, opts) do
      struct
      |> Map.from_struct()
      |> Enum.reduce(%{}, fn
        {_key, nil}, acc -> acc
        {:last_modified, val}, acc -> Map.put(acc, :lastModified, val)
        {key, val}, acc -> Map.put(acc, key, val)
      end)
      |> Jason.Encode.map(opts)
    end
  end
end
