defmodule MCP.Protocol.Types.ResourceTemplate do
  @moduledoc """
  An MCP resource template — a URI template (RFC 6570) for dynamic resources.
  """

  alias MCP.Protocol.Types.{Annotations, Icon}

  defstruct [:uri_template, :name, :title, :description, :mime_type, :annotations, :icons, :meta]

  @type t :: %__MODULE__{
          uri_template: String.t(),
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          mime_type: String.t() | nil,
          annotations: Annotations.t() | nil,
          icons: [Icon.t()] | nil,
          meta: map() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      uri_template: Map.fetch!(map, "uriTemplate"),
      name: Map.fetch!(map, "name"),
      title: Map.get(map, "title"),
      description: Map.get(map, "description"),
      mime_type: Map.get(map, "mimeType"),
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
        {:uri_template, val}, acc -> Map.put(acc, :uriTemplate, val)
        {:mime_type, val}, acc -> Map.put(acc, :mimeType, val)
        {:meta, val}, acc -> Map.put(acc, :_meta, val)
        {key, val}, acc -> Map.put(acc, key, val)
      end)
      |> Jason.Encode.map(opts)
    end
  end
end
