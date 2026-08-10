defmodule MCP.Protocol.ToolRouting do
  @moduledoc false

  @safe_integer_max 9_007_199_254_740_991
  @header_token ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/

  @type descriptor :: %{header: String.t(), path: [String.t()], type: String.t()}

  @spec descriptors(map()) :: {:ok, [descriptor()]} | {:error, atom()}
  def descriptors(schema) when is_map(schema) do
    with {:ok, descriptors} <- walk(schema, :root, []),
         true <- unique_headers?(descriptors) do
      {:ok, descriptors}
    else
      false -> {:error, :duplicate_header_name}
      {:error, reason} -> {:error, reason}
    end
  end

  def descriptors(_schema), do: {:error, :invalid_schema}

  @spec argument_value(map(), descriptor()) ::
          :missing | {:ok, String.t()} | {:error, :invalid_argument_type | :unsafe_integer}
  def argument_value(arguments, descriptor) when is_map(arguments) do
    case fetch_argument(arguments, descriptor.path) do
      nil -> :missing
      :invalid_path -> {:error, :invalid_argument_type}
      value -> encode_value(value, descriptor.type)
    end
  end

  def argument_value(_arguments, _descriptor), do: {:error, :invalid_argument_type}

  defp fetch_argument(arguments, []), do: arguments

  defp fetch_argument(arguments, [key | rest]) when is_map(arguments) do
    case Map.fetch(arguments, key) do
      {:ok, nil} -> nil
      {:ok, value} -> fetch_argument(value, rest)
      :error -> nil
    end
  end

  defp fetch_argument(_arguments, _path), do: :invalid_path

  defp walk(node, location, path) when is_map(node) do
    with {:ok, own} <- annotation_descriptor(node, location, path),
         true <- properties_allowed?(node),
         {:ok, nested} <- walk_properties(Map.get(node, "properties"), path),
         remainder = Map.drop(node, ["properties", "x-mcp-header"]),
         true <- no_annotations_outside_properties?(remainder) do
      {:ok, own ++ nested}
    else
      false -> {:error, :forbidden_annotation_location}
      {:error, reason} -> {:error, reason}
    end
  end

  defp walk(_node, _location, _path), do: {:ok, []}

  defp walk_properties(properties, path) when is_map(properties) do
    properties
    |> Enum.reduce_while({:ok, []}, fn {property, schema}, {:ok, acc} ->
      case walk(schema, :property, path ++ [property]) do
        {:ok, descriptors} -> {:cont, {:ok, [descriptors | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, descriptor_groups} -> {:ok, descriptor_groups |> Enum.reverse() |> List.flatten()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp walk_properties(_properties, _path), do: {:ok, []}

  defp properties_allowed?(%{"properties" => properties, "type" => "object"})
       when is_map(properties),
       do: true

  defp properties_allowed?(%{"properties" => properties, "type" => types})
       when is_map(properties) and is_list(types),
       do: "object" in types and Enum.all?(types, &(&1 in ["object", "null"]))

  defp properties_allowed?(%{"properties" => properties} = node) when is_map(properties),
    do: not Map.has_key?(node, "type")

  defp properties_allowed?(_node), do: true

  defp annotation_descriptor(node, _location, _path)
       when not is_map_key(node, "x-mcp-header"),
       do: {:ok, []}

  defp annotation_descriptor(%{"x-mcp-header" => name, "type" => type}, :property, path)
       when is_binary(name) and type in ["string", "boolean", "integer"] do
    if Regex.match?(@header_token, name) do
      {:ok, [%{header: name, path: path, type: type}]}
    else
      {:error, :invalid_header_name}
    end
  end

  defp annotation_descriptor(_node, _location, _path), do: {:error, :invalid_annotation}

  defp no_annotations_outside_properties?(node) when is_map(node) do
    not Map.has_key?(node, "x-mcp-header") and
      Enum.all?(node, fn {_key, value} -> no_annotations_outside_properties?(value) end)
  end

  defp no_annotations_outside_properties?(node) when is_list(node),
    do: Enum.all?(node, &no_annotations_outside_properties?/1)

  defp no_annotations_outside_properties?(_node), do: true

  defp unique_headers?(descriptors) do
    normalized = Enum.map(descriptors, &String.downcase(&1.header))
    length(normalized) == MapSet.size(MapSet.new(normalized))
  end

  defp encode_value(value, "string") when is_binary(value), do: {:ok, value}
  defp encode_value(value, "boolean") when is_boolean(value), do: {:ok, to_string(value)}

  defp encode_value(value, "integer") when is_integer(value) and abs(value) <= @safe_integer_max,
    do: {:ok, Integer.to_string(value)}

  defp encode_value(value, "integer") when is_integer(value), do: {:error, :unsafe_integer}
  defp encode_value(_value, _type), do: {:error, :invalid_argument_type}
end
