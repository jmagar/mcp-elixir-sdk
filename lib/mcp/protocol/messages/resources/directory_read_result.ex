defmodule MCP.Protocol.Messages.Resources.DirectoryReadResult do
  @moduledoc "Result of `resources/directory/read`."

  alias MCP.Protocol.OpenObject
  alias MCP.Protocol.Types.Resource

  @known_keys ~w(resources nextCursor resultType _meta)

  defstruct [:resources, :next_cursor, :meta, extra: %{}, result_type: "complete"]

  @type t :: %__MODULE__{
          resources: [Resource.t()],
          next_cursor: String.t() | nil,
          result_type: String.t(),
          meta: map() | nil,
          extra: MCP.Protocol.extra_fields()
        }

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(%{"resources" => resources} = map) when is_list(resources) do
    with :ok <- validate_envelope(map),
         true <- Enum.all?(resources, &valid_resource?/1) do
      try do
        {:ok,
         %__MODULE__{
           resources: Enum.map(resources, &Resource.from_map/1),
           next_cursor: Map.get(map, "nextCursor"),
           meta: Map.get(map, "_meta"),
           extra: OpenObject.extra(map, @known_keys)
         }}
      rescue
        _error -> {:error, :invalid_directory_read_result}
      end
    else
      _invalid -> {:error, :invalid_directory_read_result}
    end
  end

  def decode(_map), do: {:error, :invalid_directory_read_result}

  defp validate_envelope(map) do
    if valid_optional?(Map.get(map, "nextCursor"), &is_binary/1) and
         Map.get(map, "resultType", "complete") == "complete" and
         valid_optional?(Map.get(map, "_meta"), &is_map/1),
       do: :ok,
       else: {:error, :invalid_directory_read_result}
  end

  defp valid_optional?(nil, _validator), do: true
  defp valid_optional?(value, validator), do: validator.(value)

  defp valid_resource?(%{"uri" => uri, "name" => name} = resource) do
    is_binary(uri) and uri != "" and is_binary(name) and name != "" and
      valid_resource_strings?(resource) and valid_resource_structures?(resource)
  end

  defp valid_resource?(_resource), do: false

  defp valid_resource_strings?(resource) do
    valid_optional?(Map.get(resource, "title"), &is_binary/1) and
      valid_optional?(Map.get(resource, "description"), &is_binary/1) and
      valid_optional?(Map.get(resource, "mimeType"), &is_binary/1)
  end

  defp valid_resource_structures?(resource) do
    valid_optional?(Map.get(resource, "size"), &(is_integer(&1) and &1 >= 0)) and
      valid_optional?(Map.get(resource, "annotations"), &valid_annotations?/1) and
      valid_optional?(Map.get(resource, "icons"), &valid_icons?/1) and
      valid_optional?(Map.get(resource, "_meta"), &is_map/1)
  end

  defp valid_annotations?(annotations) when is_map(annotations) do
    valid_optional?(Map.get(annotations, "audience"), &valid_string_list?/1) and
      valid_optional?(Map.get(annotations, "priority"), &is_number/1) and
      valid_optional?(Map.get(annotations, "lastModified"), &is_binary/1)
  end

  defp valid_annotations?(_annotations), do: false

  defp valid_icons?(icons), do: is_list(icons) and Enum.all?(icons, &valid_icon?/1)

  defp valid_icon?(%{"src" => src} = icon) when is_binary(src) and src != "" do
    valid_optional?(Map.get(icon, "mimeType"), &is_binary/1) and
      valid_optional?(Map.get(icon, "sizes"), &valid_string_list?/1) and
      valid_optional?(Map.get(icon, "theme"), &is_binary/1)
  end

  defp valid_icon?(_icon), do: false

  defp valid_string_list?(values), do: is_list(values) and Enum.all?(values, &is_binary/1)

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{"resultType" => result.result_type, "resources" => result.resources}
    |> maybe_put("nextCursor", result.next_cursor)
    |> maybe_put("_meta", result.meta)
    |> OpenObject.merge!(result.extra, @known_keys, "resources/directory/read result")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defimpl Jason.Encoder do
    def encode(result, opts), do: Jason.Encode.map(@for.to_map(result), opts)
  end
end
