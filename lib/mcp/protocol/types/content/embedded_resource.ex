defmodule MCP.Protocol.Types.Content.EmbeddedResource do
  @moduledoc """
  An embedded resource content block (type: "resource").
  """

  alias MCP.Protocol.Types.{Annotations, ResourceContents}

  defstruct type: "resource", resource: nil, annotations: nil, meta: nil

  @type t :: %__MODULE__{
          type: String.t(),
          resource: ResourceContents.t(),
          annotations: Annotations.t() | nil,
          meta: map() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      resource: map |> Map.fetch!("resource") |> ResourceContents.from_map(),
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
