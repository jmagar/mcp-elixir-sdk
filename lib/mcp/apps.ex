defmodule MCP.Apps do
  @moduledoc """
  Stable MCP Apps (SEP-1865, 2026-01-26) helpers.

  This module implements the SDK-side wire contract. Browser iframe rendering,
  `postMessage` delivery, consent, and effective CSP/Permission Policy remain
  responsibilities of an embedding host.
  """

  @extension "io.modelcontextprotocol/ui"
  @mime_type "text/html;profile=mcp-app"
  @protocol_version "2026-01-26"

  def extension, do: @extension
  def mime_type, do: @mime_type
  def protocol_version, do: @protocol_version

  @doc "Returns extension settings suitable for client/server capabilities."
  def capability(mime_types \\ [@mime_type]) when is_list(mime_types) do
    if mime_types != [] and Enum.all?(mime_types, &is_binary/1) and @mime_type in mime_types do
      {@extension, %{"mimeTypes" => mime_types}}
    else
      raise ArgumentError, "MCP Apps capability must include #{@mime_type}"
    end
  end

  @doc "Returns client capabilities with MCP Apps enabled."
  def client_capabilities(capabilities \\ %MCP.Protocol.Capabilities.ClientCapabilities{}) do
    {extension, settings} = capability()
    extensions = Map.put(capabilities.extensions || %{}, extension, settings)
    %{capabilities | extensions: extensions}
  end

  @doc "Adds MCP Apps to an existing string-keyed extension settings map."
  def extensions(extensions \\ %{}) when is_map(extensions) do
    {extension, settings} = capability()
    Map.put(extensions, extension, settings)
  end

  @doc "True when capabilities negotiate the stable HTML profile."
  def negotiated?(%{extensions: extensions}), do: negotiated?(extensions)
  def negotiated?(%{"extensions" => extensions}), do: negotiated?(extensions)

  def negotiated?(extensions) when is_map(extensions) do
    case Map.get(extensions, @extension) do
      %{"mimeTypes" => mime_types} when is_list(mime_types) -> @mime_type in mime_types
      _other -> false
    end
  end

  def negotiated?(_capabilities), do: false
end
