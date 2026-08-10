defmodule MCP.Protocol.Types.Content.TextContent do
  @moduledoc """
  Text content block.
  """

  alias MCP.Protocol.Types.Annotations

  defstruct type: "text", text: nil, annotations: nil, meta: nil

  @type t :: %__MODULE__{
          type: String.t(),
          text: String.t(),
          annotations: Annotations.t() | nil,
          meta: map() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      text: Map.fetch!(map, "text"),
      annotations: map |> Map.get("annotations") |> parse_annotations(),
      meta: Map.get(map, "_meta")
    }
  end

  defp parse_annotations(nil), do: nil
  defp parse_annotations(map), do: Annotations.from_map(map)

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
