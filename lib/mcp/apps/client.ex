defmodule MCP.Apps.Client do
  @moduledoc "Apps-aware helpers over an existing `MCP.Client` process."

  alias MCP.Apps.{ResolvedApp, Validator}

  @spec resolve(pid(), map(), keyword()) :: {:ok, ResolvedApp.t()} | {:error, term()}
  def resolve(client, tool, opts \\ []) when is_pid(client) and is_map(tool) do
    meta = Map.get(tool, "_meta") || Map.get(tool, :_meta) || %{}

    with true <- Process.alive?(client) or {:error, :stale_client_binding},
         {:ok, tool_ui} <- Validator.tool_meta(meta, opts),
         {:ok, result} <- MCP.Client.read_resource(client, tool_ui.resource_uri, opts),
         {:ok, content, merged_ui} <- resolve_result(result, tool_ui.resource_uri, opts) do
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
  def call_tool(%ResolvedApp{client: client, tool: tool}, name, arguments \\ %{}, opts \\ []) do
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

  defp resolve_result(%{"contents" => [content]}, uri, opts) do
    content_uri = Map.get(content, "uri")
    mime = Map.get(content, "mimeType")
    text = Map.get(content, "text")
    blob = Map.get(content, "blob")
    meta = Map.get(content, "_meta")

    with true <- content_uri == uri or {:error, :resource_uri_mismatch},
         {:ok, validated} <- Validator.resource(content_uri, mime, text, blob, meta, opts) do
      {:ok, validated.content, validated.ui}
    end
  end

  defp resolve_result(%{contents: [content]}, uri, opts) when is_map(content) do
    resolve_result(
      %{"contents" => [Map.new(content, fn {key, value} -> {Atom.to_string(key), value} end)]},
      uri,
      opts
    )
  end

  defp resolve_result(_result, _uri, _opts), do: {:error, :expected_one_app_resource}
end
