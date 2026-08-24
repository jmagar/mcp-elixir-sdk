defmodule MCP.Protocol.Messages.Skills.ListParams do
  @moduledoc "Parameters for `skills/list`."

  defstruct [:cursor, :meta]

  @type t :: %__MODULE__{cursor: String.t() | nil, meta: map() | nil}

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(map) when is_map(map) do
    cursor = Map.get(map, "cursor")
    meta = Map.get(map, "_meta")

    if Enum.all?(Map.keys(map), &(&1 in ["cursor", "_meta"])) and
         optional_member?(map, "cursor", &is_binary/1) and
         optional_member?(map, "_meta", &is_map/1) do
      {:ok, %__MODULE__{cursor: cursor, meta: meta}}
    else
      {:error, :invalid_skills_list_params}
    end
  end

  def decode(_map), do: {:error, :invalid_skills_list_params}

  defp optional_member?(map, key, validator) do
    not Map.has_key?(map, key) or validator.(Map.fetch!(map, key))
  end

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
