defmodule MCP.Protocol.Messages.Resources.DirectoryReadParams do
  @moduledoc "Parameters for `resources/directory/read`."

  defstruct [:uri, :cursor, :meta]

  @type t :: %__MODULE__{uri: String.t(), cursor: String.t() | nil, meta: map() | nil}

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(%{"uri" => uri} = map) when is_binary(uri) do
    cursor = Map.get(map, "cursor")
    meta = Map.get(map, "_meta")

    if (is_nil(cursor) or is_binary(cursor)) and (is_nil(meta) or is_map(meta)),
      do: {:ok, %__MODULE__{uri: uri, cursor: cursor, meta: meta}},
      else: {:error, :invalid_directory_read_params}
  end

  def decode(_map), do: {:error, :invalid_directory_read_params}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = params) do
    %{"uri" => params.uri}
    |> maybe_put("cursor", params.cursor)
    |> maybe_put("_meta", params.meta)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defimpl Jason.Encoder do
    def encode(params, opts), do: Jason.Encode.map(@for.to_map(params), opts)
  end
end
