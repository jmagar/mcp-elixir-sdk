defmodule MCP.Apps.Client do
  @moduledoc "Apps-aware helpers over an existing `MCP.Client` process."

  alias MCP.Apps.{ResolvedApp, Validator}

  @spec resolve(pid(), map(), keyword()) :: {:ok, ResolvedApp.t()} | {:error, term()}
  def resolve(client, tool, opts \\ []) when is_pid(client) and is_map(tool) do
    meta = Map.get(tool, "_meta") || Map.get(tool, :_meta) || %{}

    with true <- Process.alive?(client) or {:error, :stale_client_binding},
         :ok <- negotiated(client),
         {:ok, tool_ui} <- Validator.tool_meta(meta, opts),
         {:ok, listing_meta} <-
           listing_metadata(Keyword.get(opts, :resource), tool_ui.resource_uri, opts),
         {:ok, result} <- MCP.Client.read_resource(client, tool_ui.resource_uri, opts),
         {:ok, content, merged_ui} <-
           resolve_result(result, tool_ui.resource_uri, listing_meta, opts) do
      {:ok,
       %ResolvedApp{
         client: client,
         tool: tool,
         resource_uri: tool_ui.resource_uri,
         content: content,
         ui: merged_ui,
         raw_result: result
       }}
    else
      false -> {:error, :stale_client_binding}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_app_resource}
    end
  end

  @doc "Calls an app-visible tool through the exact client binding used to resolve it."
  def call_tool(%ResolvedApp{client: client, tool: tool}, arguments \\ %{}, opts \\ []) do
    name = Map.get(tool, "name") || Map.get(tool, :name)
    call_tool_descriptor(client, tool, name, arguments, opts)
  end

  @doc "Calls an app-visible sibling descriptor through a resolved App's exact client."
  def call_sibling_tool(%ResolvedApp{client: client}, tool, arguments \\ %{}, opts \\ [])
      when is_map(tool) do
    name = Map.get(tool, "name") || Map.get(tool, :name)
    call_tool_descriptor(client, tool, name, arguments, opts)
  end

  defp call_tool_descriptor(client, tool, name, arguments, opts) do
    meta = Map.get(tool, "_meta") || Map.get(tool, :_meta) || %{}

    with true <- Process.alive?(client) or {:error, :stale_client_binding},
         {:ok, %{visibility: visibility}} <- Validator.tool_meta(meta, opts),
         true <- "app" in visibility or {:error, :tool_not_app_visible},
         true <- is_binary(name) or {:error, :invalid_tool_name} do
      MCP.Client.call_tool(client, name, arguments, opts)
    else
      false -> {:error, :stale_client_binding}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_result(%{"contents" => [content]}, uri, listing_meta, opts) when is_map(content) do
    content_uri = Map.get(content, "uri")
    mime = Map.get(content, "mimeType")
    text = Map.get(content, "text")
    blob = Map.get(content, "blob")
    meta = Map.get(content, "_meta")

    with true <- content_uri == uri or {:error, :resource_uri_mismatch},
         {:ok, validated} <- Validator.resource(content_uri, mime, text, blob, meta, opts),
         {:ok, merged_ui} <- Validator.merge_resource_meta(listing_meta, meta, opts) do
      {:ok, validated.content, merged_ui}
    end
  end

  defp resolve_result(%{contents: [content]}, uri, listing_meta, opts) when is_map(content) do
    normalized = %{
      "uri" => value(content, "uri", :uri),
      "mimeType" => value(content, "mimeType", :mime_type),
      "text" => value(content, "text", :text),
      "blob" => value(content, "blob", :blob),
      "_meta" => value(content, "_meta", :meta)
    }

    resolve_result(%{"contents" => [normalized]}, uri, listing_meta, opts)
  end

  defp resolve_result(_result, _uri, _listing_meta, _opts),
    do: {:error, :expected_one_app_resource}

  defp listing_metadata(nil, _uri, _opts), do: {:ok, nil}

  defp listing_metadata(resource, uri, opts) when is_map(resource) do
    resource_uri = value(resource, "uri", :uri)
    mime = value(resource, "mimeType", :mimeType)
    meta = value(resource, "_meta", :_meta)

    with true <- resource_uri == uri or {:error, :resource_uri_mismatch},
         true <- mime == MCP.Apps.mime_type() or {:error, :resource_mime_mismatch},
         {:ok, _validated} <- Validator.resource_metadata(meta, opts) do
      {:ok, meta}
    end
  end

  defp listing_metadata(_resource, _uri, _opts), do: {:error, :invalid_resource_descriptor}

  defp negotiated(client) do
    client_support = MCP.Client.client_capabilities(client)
    server_support = MCP.Client.server_capabilities(client)

    if MCP.Apps.negotiated?(client_support) and MCP.Apps.negotiated?(server_support),
      do: :ok,
      else: {:error, :apps_not_negotiated}
  end

  defp value(map, string_key, atom_key) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key)
    end
  end
end
