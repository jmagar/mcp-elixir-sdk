defmodule MCP.Apps.AppDefinition do
  @moduledoc """
  Immutable linked MCP App tool and UI resource definition.

  The definition produces ordinary MCP tool/resource maps and does not replace
  the existing handler callbacks or dispatch pipeline.
  """

  alias MCP.Apps.Validator

  defstruct [:tool, :resource, :contents]

  @type t :: %__MODULE__{tool: map(), resource: map(), contents: map()}

  @spec new(map(), map(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(tool, resource, contents, opts \\ [])

  def new(tool, resource, contents, opts)
      when is_map(tool) and is_map(resource) and is_map(contents) do
    tool_meta = value(tool, "_meta", :_meta, %{})
    uri = value(resource, "uri", :uri)
    mime = value(resource, "mimeType", :mimeType)
    content_uri = value(contents, "uri", :uri)
    content_mime = value(contents, "mimeType", :mimeType)
    text = value(contents, "text", :text)
    blob = value(contents, "blob", :blob)
    content_meta = value(contents, "_meta", :_meta)

    with {:ok, %{resource_uri: ^uri}} <- Validator.tool_meta(tool_meta, opts),
         true <- content_uri == uri or {:error, :resource_uri_mismatch},
         true <- content_mime == mime or {:error, :resource_mime_mismatch},
         {:ok, _validated} <- Validator.resource(uri, mime, text, blob, content_meta, opts) do
      {:ok, %__MODULE__{tool: tool, resource: resource, contents: contents}}
    else
      false -> {:error, :invalid_app_definition}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_app_definition}
    end
  end

  def new(_tool, _resource, _contents, _opts), do: {:error, :invalid_app_definition}

  @spec catalog([t()]) :: {:ok, map()} | {:error, term()}
  def catalog(definitions) when is_list(definitions) do
    Enum.reduce_while(definitions, {:ok, %{tools: %{}, resources: %{}, contents: %{}}}, fn
      %__MODULE__{} = definition, {:ok, catalog} ->
        name = Map.get(definition.tool, "name") || Map.get(definition.tool, :name)
        uri = Map.get(definition.resource, "uri") || Map.get(definition.resource, :uri)

        if Map.has_key?(catalog.tools, name) or Map.has_key?(catalog.resources, uri) do
          {:halt, {:error, :duplicate_app_definition}}
        else
          {:cont,
           {:ok,
            %{
              tools: Map.put(catalog.tools, name, definition.tool),
              resources: Map.put(catalog.resources, uri, definition.resource),
              contents: Map.put(catalog.contents, uri, definition.contents)
            }}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_app_definition}}
    end)
  end

  @doc "Returns the helper-owned model inventory, filtering before pagination."
  def model_tools(%{tools: tools}) do
    tools
    |> Map.values()
    |> Enum.filter(fn tool ->
      meta = Map.get(tool, "_meta") || Map.get(tool, :_meta) || %{}

      case Validator.tool_meta(meta) do
        {:ok, %{visibility: visibility}} -> "model" in visibility
        {:error, _reason} -> false
      end
    end)
  end

  @doc "Returns an app-visible tool from the helper-owned catalog."
  def app_tool(%{tools: tools}, name) when is_binary(name) do
    case Map.fetch(tools, name) do
      {:ok, tool} ->
        meta = value(tool, "_meta", :_meta, %{})
        app_visible(Validator.tool_meta(meta), tool)

      :error ->
        {:error, :unknown_app_tool}
    end
  end

  @doc "Returns helper-owned UI contents without invoking application work."
  def read_resource(%{contents: contents}, uri) when is_binary(uri) do
    case Map.fetch(contents, uri) do
      {:ok, content} -> {:ok, content, %{ttl_ms: 0, cache_scope: "private"}}
      :error -> {:error, :unknown_app_resource}
    end
  end

  defp value(map, string_key, atom_key, default \\ nil) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key, default)
    end
  end

  defp app_visible({:ok, %{visibility: visibility}}, tool) do
    if "app" in visibility, do: {:ok, tool}, else: {:error, :tool_not_app_visible}
  end

  defp app_visible({:error, _reason} = error, _tool), do: error
end
