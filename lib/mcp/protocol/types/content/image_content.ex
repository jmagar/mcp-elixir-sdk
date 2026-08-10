defmodule MCP.Protocol.Types.Content.ImageContent do
  @moduledoc """
  Base64-encoded image content block.
  """

  alias MCP.Protocol.Types.Annotations

  defstruct type: "image", data: nil, mime_type: nil, annotations: nil, meta: nil

  @type t :: %__MODULE__{
          type: String.t(),
          data: String.t(),
          mime_type: String.t(),
          annotations: Annotations.t() | nil,
          meta: map() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      data: Map.fetch!(map, "data"),
      mime_type: Map.fetch!(map, "mimeType"),
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
        {:mime_type, val}, acc -> Map.put(acc, :mimeType, val)
        {:meta, val}, acc -> Map.put(acc, :_meta, val)
        {key, val}, acc -> Map.put(acc, key, val)
      end)
      |> Jason.Encode.map(opts)
    end
  end
end
