defmodule MCP.Apps.Validator do
  @moduledoc false

  alias MCP.Apps.Limits

  @visibility ["model", "app"]
  @permissions ["camera", "microphone", "geolocation", "clipboardWrite"]
  @csp_fields ["connectDomains", "resourceDomains", "frameDomains", "baseUriDomains"]

  def tool_meta(meta, opts \\ [])

  def tool_meta(meta, opts) when is_map(meta) do
    limits = limits(opts)
    ui = fetch_any(meta, "ui", :ui)
    flat = fetch_any(meta, "ui/resourceUri", :"ui/resourceUri")
    ui_or_flat = if is_nil(ui) and not is_nil(flat), do: %{}, else: ui

    with {:ok, ui} <- require_map(ui_or_flat, :missing_ui_metadata),
         nested <- fetch_any(ui, "resourceUri", :resourceUri),
         :ok <- compatible_uri(nested, flat),
         {:ok, uri} <- ui_uri(nested || flat, limits),
         {:ok, visibility} <- validate_tool_ui(meta, ui, limits) do
      {:ok, %{resource_uri: uri, visibility: visibility, raw: meta}}
    end
  end

  def tool_meta(_meta, _opts), do: {:error, :invalid_tool_metadata}

  @doc false
  def tool_visibility(meta, opts \\ [])

  def tool_visibility(meta, opts) when is_map(meta) do
    limits = limits(opts)
    ui = fetch_any(meta, "ui", :ui)
    flat = fetch_any(meta, "ui/resourceUri", :"ui/resourceUri")
    ui_or_flat = if is_nil(ui) and not is_nil(flat), do: %{}, else: ui

    with {:ok, ui} <- require_map(ui_or_flat, :missing_ui_metadata),
         nested <- fetch_any(ui, "resourceUri", :resourceUri),
         :ok <- compatible_uri(nested, flat),
         uri <- if(is_nil(nested), do: flat, else: nested),
         :ok <- optional_ui_uri(uri, limits) do
      validate_tool_ui(meta, ui, limits)
    end
  end

  def tool_visibility(_meta, _opts), do: {:error, :invalid_tool_metadata}

  def resource(uri, mime_type, text, blob, meta, opts \\ []) do
    limits = limits(opts)

    with {:ok, uri} <- ui_uri(uri, limits),
         :ok <- exact_mime(mime_type),
         {:ok, content} <- one_content(text, blob, limits),
         {:ok, ui_meta} <- resource_meta(meta, limits) do
      {:ok, %{uri: uri, mime_type: mime_type, content: content, ui: ui_meta, raw_meta: meta}}
    end
  end

  def merge_resource_meta(list_meta, content_meta, opts \\ []) do
    limits = limits(opts)

    with {:ok, listed} <- resource_meta(list_meta, limits),
         {:ok, content} <- resource_meta(content_meta, limits) do
      {:ok, Map.merge(listed, content)}
    end
  end

  def resource_metadata(meta, opts \\ []), do: resource_meta(meta, limits(opts))

  def validate_json(value, opts \\ []), do: json_budget(value, limits(opts))

  def ui_uri(uri, %Limits{} = limits) when is_binary(uri) do
    parsed = URI.parse(uri)

    cond do
      byte_size(uri) > limits.max_uri_bytes ->
        {:error, :uri_too_large}

      parsed.scheme != "ui" ->
        {:error, :invalid_ui_uri}

      is_nil(parsed.host) or parsed.host == "" ->
        {:error, :invalid_ui_uri}

      contains_control?(uri) ->
        {:error, :invalid_ui_uri}

      true ->
        {:ok, uri}
    end
  end

  def ui_uri(_uri, _limits), do: {:error, :invalid_ui_uri}

  def safe_uri(uri) when is_binary(uri) do
    parsed = URI.parse(uri)
    fingerprint = :crypto.hash(:sha256, uri) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    "#{parsed.scheme || "invalid"}://#{parsed.host || "invalid"}/…##{fingerprint}"
  end

  defp resource_meta(nil, _limits), do: {:ok, %{}}

  defp resource_meta(meta, limits) when is_map(meta) do
    ui = Map.get(meta, "ui") || Map.get(meta, :ui) || %{}

    with :ok <- json_budget(meta, limits),
         {:ok, ui} <- require_map(ui, :invalid_resource_ui_metadata),
         {:ok, csp} <- csp(fetch_any(ui, "csp", :csp), limits),
         {:ok, permissions} <- permissions(fetch_any(ui, "permissions", :permissions)),
         :ok <- optional_binary(ui, "domain"),
         :ok <- optional_boolean(ui, "prefersBorder") do
      {:ok,
       %{}
       |> maybe_put(:csp, csp)
       |> maybe_put(:permissions, permissions)
       |> maybe_put(:domain, fetch_any(ui, "domain", :domain))
       |> maybe_put(:prefers_border, fetch_any(ui, "prefersBorder", :prefersBorder))}
    end
  end

  defp resource_meta(_meta, _limits), do: {:error, :invalid_resource_metadata}

  defp csp(nil, _limits), do: {:ok, nil}

  defp csp(csp, limits) when is_map(csp) do
    Enum.reduce_while(@csp_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case validate_origins(field, Map.get(csp, field), limits) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, origins} -> {:cont, {:ok, Map.put(acc, field, origins)}}
        error -> {:halt, error}
      end
    end)
  end

  defp csp(_csp, _limits), do: {:error, :invalid_csp}

  defp validate_origins(_field, nil, _limits), do: {:ok, nil}

  defp validate_origins(field, origins, limits) when is_list(origins) do
    cond do
      length(origins) > limits.max_csp_entries -> {:error, :too_many_csp_entries}
      Enum.all?(origins, &valid_origin?(&1, field, limits)) -> {:ok, origins}
      true -> {:error, :invalid_csp_origin}
    end
  end

  defp validate_origins(_field, _origins, _limits), do: {:error, :invalid_csp_origins}

  defp valid_origin?(origin, field, limits) when is_binary(origin) do
    parsed = URI.parse(origin)

    byte_size(origin) <= limits.max_csp_entry_bytes and
      valid_origin_scheme?(parsed.scheme, field) and valid_origin_parts?(parsed) and
      valid_origin_wildcard?(parsed.host, field) and not contains_control?(origin)
  end

  defp valid_origin?(_origin, _field, _limits), do: false

  defp permissions(nil), do: {:ok, nil}

  defp permissions(permissions) when is_map(permissions) do
    if Enum.all?(permissions, fn {key, value} -> key in @permissions and value == %{} end),
      do: {:ok, permissions},
      else: {:error, :invalid_permissions}
  end

  defp permissions(_permissions), do: {:error, :invalid_permissions}

  defp one_content(text, nil, limits) when is_binary(text) do
    if byte_size(text) <= limits.max_resource_bytes,
      do: {:ok, {:text, text}},
      else: {:error, :resource_too_large}
  end

  defp one_content(nil, blob, limits) when is_binary(blob) do
    max_encoded = div(limits.max_resource_bytes + 2, 3) * 4

    if byte_size(blob) > max_encoded do
      {:error, :resource_too_large}
    else
      case Base.decode64(blob) do
        {:ok, decoded} when byte_size(decoded) <= limits.max_resource_bytes ->
          {:ok, {:blob, blob}}

        {:ok, _decoded} ->
          {:error, :resource_too_large}

        :error ->
          {:error, :invalid_base64}
      end
    end
  end

  defp one_content(_text, _blob, _limits), do: {:error, :exactly_one_content_required}

  defp visibility(nil), do: {:ok, @visibility}

  defp visibility(values) when is_list(values) and values != [] do
    if Enum.uniq(values) == values and Enum.all?(values, &(&1 in @visibility)),
      do: {:ok, values},
      else: {:error, :invalid_visibility}
  end

  defp visibility(_values), do: {:error, :invalid_visibility}

  defp compatible_uri(nil, _flat), do: :ok
  defp compatible_uri(_nested, nil), do: :ok
  defp compatible_uri(uri, uri), do: :ok
  defp compatible_uri(_nested, _flat), do: {:error, :conflicting_resource_uri}

  defp optional_ui_uri(nil, _limits), do: :ok

  defp optional_ui_uri(uri, limits) do
    case ui_uri(uri, limits) do
      {:ok, _uri} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_tool_ui(meta, ui, limits) do
    with {:ok, visibility} <- visibility(fetch_any(ui, "visibility", :visibility)),
         :ok <- reject_tool_policy(ui),
         :ok <- json_budget(meta, limits) do
      {:ok, visibility}
    end
  end

  defp reject_tool_policy(ui) do
    if Map.has_key?(ui, "csp") or Map.has_key?(ui, :csp) or
         Map.has_key?(ui, "permissions") or Map.has_key?(ui, :permissions),
       do: {:error, :resource_policy_on_tool},
       else: :ok
  end

  defp exact_mime("text/html;profile=mcp-app"), do: :ok
  defp exact_mime(_mime), do: {:error, :invalid_mime_type}

  defp optional_binary(map, key) do
    value = if key == "domain", do: fetch_any(map, key, :domain), else: Map.get(map, key)

    if is_nil(value) or is_binary(value), do: :ok, else: {:error, :invalid_resource_metadata}
  end

  defp optional_boolean(map, key) do
    value = Map.get(map, key) || Map.get(map, :prefersBorder)
    if is_nil(value) or is_boolean(value), do: :ok, else: {:error, :invalid_resource_metadata}
  end

  defp json_budget(value, limits) do
    case count_nodes(value, 0, 0, limits) do
      {:ok, _nodes} -> :ok
      error -> error
    end
  end

  defp count_nodes(_value, depth, _nodes, limits) when depth > limits.max_depth,
    do: {:error, :metadata_too_deep}

  defp count_nodes(_value, _depth, nodes, limits) when nodes >= limits.max_nodes,
    do: {:error, :metadata_too_large}

  defp count_nodes(map, depth, nodes, limits) when is_map(map) do
    Enum.reduce_while(map, {:ok, nodes + 1}, &count_map_entry(&1, &2, depth, limits))
  end

  defp count_nodes(list, depth, nodes, limits) when is_list(list) do
    Enum.reduce_while(list, {:ok, nodes + 1}, fn value, {:ok, count} ->
      case count_nodes(value, depth + 1, count, limits) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp count_nodes(value, _depth, nodes, _limits)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: {:ok, nodes + 1}

  defp count_nodes(_value, _depth, _nodes, _limits), do: {:error, :invalid_json_value}

  defp count_map_entry({key, value}, {:ok, count}, depth, limits) when is_binary(key) do
    case count_nodes(value, depth + 1, count, limits) do
      {:ok, next} -> {:cont, {:ok, next}}
      error -> {:halt, error}
    end
  end

  defp count_map_entry(_entry, _acc, _depth, _limits),
    do: {:halt, {:error, :non_string_metadata_key}}

  defp valid_origin_scheme?("https", _field), do: true
  defp valid_origin_scheme?("wss", "connectDomains"), do: true
  defp valid_origin_scheme?(_scheme, _field), do: false

  defp valid_origin_parts?(parsed) do
    parsed.host not in [nil, ""] and is_nil(parsed.userinfo) and parsed.path in [nil, ""] and
      is_nil(parsed.query) and is_nil(parsed.fragment)
  end

  defp valid_origin_wildcard?(host, field) do
    case String.split(host, "*", parts: 3) do
      [_host] -> true
      ["", suffix] -> field == "resourceDomains" and String.starts_with?(suffix, ".")
      _other -> false
    end
  end

  defp require_map(value, _reason) when is_map(value), do: {:ok, value}
  defp require_map(_value, reason), do: {:error, reason}

  defp fetch_any(map, string_key, atom_key) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key)
    end
  end

  defp contains_control?(value), do: String.match?(value, ~r/[\x00-\x1F\x7F]/)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp limits(opts), do: Limits.new(Keyword.get(opts, :limits, []))
end
