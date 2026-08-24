defmodule MCP.Protocol.Types.ResourceContents do
  @moduledoc """
  Contents of a resource, returned by resources/read.

  Either `text` or `blob` will be set, not both.
  """

  alias MCP.Protocol.OpenObject

  @known_keys ["uri", "mimeType", "text", "blob", "_meta"]

  defstruct [:uri, :mime_type, :text, :blob, :meta, extra: %{}]

  @type t :: %__MODULE__{
          uri: String.t(),
          mime_type: String.t() | nil,
          text: String.t() | nil,
          blob: String.t() | nil,
          meta: map() | nil,
          extra: map()
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      uri: Map.fetch!(map, "uri"),
      mime_type: Map.get(map, "mimeType"),
      text: Map.get(map, "text"),
      blob: Map.get(map, "blob"),
      meta: Map.get(map, "_meta"),
      extra: OpenObject.extra(map, @known_keys)
    }
  end

  defimpl Jason.Encoder, for: __MODULE__ do
    def encode(struct, opts) do
      known =
        struct
        |> Map.from_struct()
        |> Enum.reduce(%{}, fn
          {:extra, _val}, acc -> acc
          {_key, nil}, acc -> acc
          {:mime_type, val}, acc -> Map.put(acc, :mimeType, val)
          {:meta, val}, acc -> Map.put(acc, :_meta, val)
          {key, val}, acc -> Map.put(acc, key, val)
        end)

      OpenObject.merge!(
        known,
        struct.extra,
        ~w(uri mimeType text blob _meta),
        "resource contents"
      )
      |> Jason.Encode.map(opts)
    end
  end
end
