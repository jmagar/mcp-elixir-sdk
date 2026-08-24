defmodule MCP.Protocol.Types.Skill do
  @moduledoc """
  A lossless SEP-2640 skill catalog entry.

  `resources` is either `:dynamic` or a complete list of `SkillResource`
  values. Decoding and validation are deliberately separate so callers can
  preserve a well-formed entry even when it exceeds their local loading policy.
  """

  alias MCP.Protocol.ExtensionCapabilities
  alias MCP.Protocol.Types.SkillResource

  @name ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @default_limits [max_depth: 32, max_nodes: 16_384, max_bytes: 1_048_576]

  defstruct [:uri, :frontmatter, :resources, :meta]

  @type resources :: :dynamic | [SkillResource.t()]
  @type t :: %__MODULE__{
          uri: String.t(),
          frontmatter: map(),
          resources: resources(),
          meta: map() | nil
        }

  @spec decode(term(), keyword()) :: {:ok, t()} | {:error, term()}
  def decode(map, opts \\ [])

  def decode(%{"uri" => uri, "frontmatter" => frontmatter, "resources" => resources} = map, opts)
      when is_binary(uri) and is_map(frontmatter) do
    with :ok <- only_keys(map, ~w(uri frontmatter resources _meta)),
         :ok <- bounded_json(frontmatter, opts),
         :ok <- bounded_meta(Map.get(map, "_meta"), opts),
         {:ok, decoded_resources} <- decode_resources(resources) do
      {:ok,
       %__MODULE__{
         uri: uri,
         frontmatter: frontmatter,
         resources: decoded_resources,
         meta: Map.get(map, "_meta")
       }}
    end
  end

  def decode(_map, _opts), do: {:error, :invalid_skill}

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{frontmatter: frontmatter, meta: meta, resources: resources} = skill)
      when is_map(frontmatter) and (is_nil(meta) or is_map(meta)) and
             (resources == :dynamic or is_list(resources)) do
    with {:ok, root} <- skill_root(skill.uri, skill.frontmatter),
         do: validate_resources(skill.resources, skill.uri, root)
  end

  def validate(%__MODULE__{}), do: {:error, :invalid_skill}

  @spec decode_and_validate(term(), keyword()) :: {:ok, t()} | {:error, term()}
  def decode_and_validate(map, opts \\ []) do
    with {:ok, skill} <- decode(map, opts), :ok <- validate(skill), do: {:ok, skill}
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = skill) do
    %{
      "uri" => skill.uri,
      "frontmatter" => skill.frontmatter,
      "resources" => encode_resources(skill.resources)
    }
    |> maybe_put("_meta", skill.meta)
  end

  @doc "Returns manifest totals without imposing a consumer acceptance policy."
  @spec manifest_size(t()) :: %{resources: non_neg_integer(), bytes: non_neg_integer()} | :dynamic
  def manifest_size(%__MODULE__{resources: :dynamic}), do: :dynamic

  def manifest_size(%__MODULE__{resources: resources}) do
    Enum.reduce(resources, %{resources: 0, bytes: 0}, fn resource, totals ->
      %{resources: totals.resources + 1, bytes: totals.bytes + resource.size}
    end)
  end

  defp decode_resources("dynamic"), do: {:ok, :dynamic}

  defp decode_resources(resources) when is_list(resources) do
    resources
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case SkillResource.decode(value) do
        {:ok, resource} -> {:cont, {:ok, [resource | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :empty_skill_manifest}
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_resources(_value), do: {:error, :invalid_skill_resources}

  defp validate_resources(:dynamic, _skill_uri, _root), do: :ok

  defp validate_resources([], _skill_uri, _root), do: {:error, :empty_skill_manifest}

  defp validate_resources(resources, skill_uri, root) do
    if Enum.all?(resources, &match?(%SkillResource{}, &1)) do
      resources
      |> Enum.reduce_while({:ok, MapSet.new(), false}, fn resource, state ->
        validate_resource(resource, skill_uri, root, state)
      end)
      |> case do
        {:ok, _seen, true} -> :ok
        {:ok, _seen, false} -> {:error, :missing_skill_md_resource}
        error -> error
      end
    else
      {:error, :invalid_skill_resources}
    end
  end

  defp validate_resource(resource, skill_uri, root, {:ok, seen, has_skill}) do
    with {:ok, canonical_uri} <- contained_resource?(resource.uri, root),
         false <- MapSet.member?(seen, canonical_uri) do
      {:cont, {:ok, MapSet.put(seen, canonical_uri), has_skill or resource.uri == skill_uri}}
    else
      true -> {:halt, {:error, :duplicate_skill_resource}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp skill_root(uri, %{"name" => name, "description" => description})
       when is_binary(name) and is_binary(description) do
    with true <- byte_size(name) <= 64 and Regex.match?(@name, name),
         {:ok, parsed, segments} <- parse_safe_uri(uri),
         true <- List.last(segments) == "SKILL.md",
         skill_segments = Enum.drop(segments, -1),
         true <- (List.last(skill_segments) || parsed.authority) == name do
      {:ok, {parsed.scheme, parsed.authority, skill_segments}}
    else
      false -> {:error, :skill_name_uri_mismatch}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_skill_uri}
    end
  end

  defp skill_root(_uri, _frontmatter), do: {:error, :invalid_skill_frontmatter}

  defp contained_resource?(uri, {scheme, authority, root_segments}) do
    with {:ok, parsed, segments} <- parse_safe_uri(uri),
         true <- parsed.scheme == scheme and parsed.authority == authority,
         true <- Enum.take(segments, length(root_segments)) == root_segments,
         true <- length(segments) > length(root_segments) do
      {:ok, {parsed.scheme, parsed.authority, segments}}
    else
      false -> {:error, :skill_resource_outside_root}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_safe_uri(uri) when is_binary(uri) do
    parsed = URI.parse(uri)

    with :ok <- require_uri_origin(parsed),
         :ok <- reject_unsafe_uri_parts(parsed),
         do: decode_segments(parsed)
  rescue
    ArgumentError -> {:error, :unsafe_skill_uri}
  end

  defp parse_safe_uri(_uri), do: {:error, :invalid_skill_uri}

  defp require_uri_origin(parsed) do
    scheme = Map.get(parsed, :scheme)
    authority = Map.get(parsed, :authority)

    if is_binary(scheme) and scheme != "" and is_binary(authority) and authority != "",
      do: :ok,
      else: {:error, :invalid_skill_uri}
  end

  defp reject_unsafe_uri_parts(%URI{userinfo: nil, fragment: nil, query: nil, path: path})
       when is_binary(path) do
    if String.contains?(path, ["\\", <<0>>]),
      do: {:error, :unsafe_skill_uri},
      else: :ok
  end

  defp reject_unsafe_uri_parts(_parsed), do: {:error, :unsafe_skill_uri}

  defp decode_segments(parsed) do
    parsed.path
    |> String.split("/", trim: true)
    |> Enum.reduce_while({:ok, []}, fn encoded, {:ok, acc} ->
      decoded = URI.decode(encoded)

      if decoded in ["", ".", ".."] or String.contains?(decoded, ["/", "\\", <<0>>]) or
           Regex.match?(~r/%[0-9A-Fa-f]{2}/, decoded) do
        {:halt, {:error, :unsafe_skill_uri}}
      else
        {:cont, {:ok, [decoded | acc]}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :invalid_skill_uri}
      {:ok, segments} -> {:ok, parsed, Enum.reverse(segments)}
      error -> error
    end
  end

  defp bounded_meta(nil, _opts), do: :ok
  defp bounded_meta(meta, opts) when is_map(meta), do: bounded_json(meta, opts)
  defp bounded_meta(_meta, _opts), do: {:error, :invalid_skill_meta}

  defp bounded_json(value, opts) do
    limits = Keyword.merge(@default_limits, opts)

    with true <- ExtensionCapabilities.json_value?(value),
         {:ok, nodes, depth} <- json_shape([{value, 1}], 0, 0, limits[:max_nodes]),
         true <- nodes <= limits[:max_nodes] and depth <= limits[:max_depth],
         {:ok, encoded} <- Jason.encode(value),
         true <- byte_size(encoded) <= limits[:max_bytes] do
      :ok
    else
      false -> {:error, :skill_metadata_limit}
      {:error, _reason} -> {:error, :invalid_skill_metadata}
    end
  end

  defp json_shape([], nodes, depth, _max_nodes), do: {:ok, nodes, depth}

  defp json_shape(_work, nodes, _depth, max_nodes) when nodes > max_nodes,
    do: {:error, :too_many_nodes}

  defp json_shape([{value, level} | rest], nodes, depth, max_nodes) when is_map(value) do
    children =
      Enum.flat_map(value, fn {key, child} -> [{key, level + 1}, {child, level + 1}] end)

    json_shape(children ++ rest, nodes + 1, max(depth, level), max_nodes)
  end

  defp json_shape([{value, level} | rest], nodes, depth, max_nodes) when is_list(value) do
    children = Enum.map(value, &{&1, level + 1})
    json_shape(children ++ rest, nodes + 1, max(depth, level), max_nodes)
  end

  defp json_shape([{_value, level} | rest], nodes, depth, max_nodes),
    do: json_shape(rest, nodes + 1, max(depth, level), max_nodes)

  defp only_keys(map, keys) do
    if Enum.all?(Map.keys(map), &(&1 in keys)), do: :ok, else: {:error, :unknown_skill_field}
  end

  defp encode_resources(:dynamic), do: "dynamic"
  defp encode_resources(resources), do: Enum.map(resources, &SkillResource.to_map/1)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defimpl Jason.Encoder do
    def encode(skill, opts), do: Jason.Encode.map(@for.to_map(skill), opts)
  end
end
