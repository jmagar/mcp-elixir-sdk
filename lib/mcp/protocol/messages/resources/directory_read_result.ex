defmodule MCP.Protocol.Messages.Resources.DirectoryReadResult do
  @moduledoc "Result of `resources/directory/read`."

  alias MCP.Protocol.Types.Resource

  defstruct [:resources, :next_cursor, :meta, result_type: "complete"]

  @type t :: %__MODULE__{
          resources: [Resource.t()],
          next_cursor: String.t() | nil,
          result_type: String.t(),
          meta: map() | nil
        }

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(%{"resources" => resources} = map) when is_list(resources) do
    with :ok <- validate_envelope(map) do
      try do
        {:ok,
         %__MODULE__{
           resources: Enum.map(resources, &Resource.from_map/1),
           next_cursor: Map.get(map, "nextCursor"),
           meta: Map.get(map, "_meta")
         }}
      rescue
        _error -> {:error, :invalid_directory_read_result}
      end
    end
  end

  def decode(_map), do: {:error, :invalid_directory_read_result}

  defp validate_envelope(map) do
    if Enum.all?(Map.keys(map), &(&1 in ~w(resources nextCursor resultType _meta))) and
         valid_optional?(Map.get(map, "nextCursor"), &is_binary/1) and
         Map.get(map, "resultType", "complete") == "complete" and
         valid_optional?(Map.get(map, "_meta"), &is_map/1),
       do: :ok,
       else: {:error, :invalid_directory_read_result}
  end

  defp valid_optional?(nil, _validator), do: true
  defp valid_optional?(value, validator), do: validator.(value)

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{"resultType" => result.result_type, "resources" => result.resources}
    |> maybe_put("nextCursor", result.next_cursor)
    |> maybe_put("_meta", result.meta)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defimpl Jason.Encoder do
    def encode(result, opts), do: Jason.Encode.map(@for.to_map(result), opts)
  end
end
