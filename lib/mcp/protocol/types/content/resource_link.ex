defmodule MCP.Protocol.Types.Content.ResourceLink do
  @moduledoc """
  A link to a resource (type: "resource_link").
  """

  alias MCP.Protocol.Types.{Annotations, Icon}

  defstruct type: "resource_link",
            uri: nil,
            name: nil,
            title: nil,
            description: nil,
            mime_type: nil,
            size: nil,
            annotations: nil,
            icons: nil,
            meta: nil

  @type t :: %__MODULE__{
          type: String.t(),
          uri: String.t(),
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          mime_type: String.t() | nil,
          size: non_neg_integer() | nil,
          annotations: Annotations.t() | nil,
          icons: [Icon.t()] | nil,
          meta: map() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      uri: Map.fetch!(map, "uri"),
      name: Map.fetch!(map, "name"),
      title: Map.get(map, "title"),
      description: Map.get(map, "description"),
      mime_type: Map.get(map, "mimeType"),
      size: Map.get(map, "size"),
      annotations: map |> Map.get("annotations") |> parse_annotations(),
      icons: map |> Map.get("icons") |> parse_icons(),
      meta: Map.get(map, "_meta")
    }
  end

  defp parse_annotations(nil), do: nil
  defp parse_annotations(map), do: Annotations.from_map(map)

  defp parse_icons(nil), do: nil
  defp parse_icons(icons), do: Enum.map(icons, &Icon.from_map/1)

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
