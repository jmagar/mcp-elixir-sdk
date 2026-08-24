defmodule MCP.Protocol.Messages.Skills.ListParams do
  @moduledoc "Parameters for `skills/list`."

  defstruct [:cursor, :meta]

  @type t :: %__MODULE__{cursor: String.t() | nil, meta: map() | nil}

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(map) when is_map(map) do
    cursor = Map.get(map, "cursor")
    meta = Map.get(map, "_meta")

    if (is_nil(cursor) or is_binary(cursor)) and (is_nil(meta) or is_map(meta)) do
      {:ok, %__MODULE__{cursor: cursor, meta: meta}}
    else
      {:error, :invalid_skills_list_params}
    end
  end

  def decode(_map), do: {:error, :invalid_skills_list_params}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = params) do
    %{}
    |> maybe_put("cursor", params.cursor)
    |> maybe_put("_meta", params.meta)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defimpl Jason.Encoder do
    def encode(params, opts), do: Jason.Encode.map(@for.to_map(params), opts)
  end
end
