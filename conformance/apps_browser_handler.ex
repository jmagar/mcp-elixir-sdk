defmodule MCP.Conformance.AppsBrowserHandler do
  @moduledoc false
  @behaviour MCP.Server.Handler

  @resource_uri "ui://interop/view.html"
  @view_tool "apps_interop_view"
  @callback_tool "apps_same_server_callback"

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_list_tools(_cursor, _ctx, _config) do
    {:ok,
     [
       %{
         "name" => @view_tool,
         "description" => "Render the MCP Elixir SDK Apps interoperability view",
         "inputSchema" => %{"type" => "object", "additionalProperties" => false},
         "_meta" => %{
           "ui" => %{"resourceUri" => @resource_uri, "visibility" => ["model", "app"]}
         }
       },
       %{
         "name" => @callback_tool,
         "description" => "Same-server callback used by the interoperability view",
         "inputSchema" => %{"type" => "object", "additionalProperties" => false},
         "_meta" => %{"ui" => %{"visibility" => ["app"]}}
       }
     ], nil}
  end

  @impl true
  def handle_call_tool(@view_tool, _arguments, _ctx, _config) do
    record("view_tool_called")
    {:ok, [%{"type" => "text", "text" => "View tool opened"}]}
  end

  def handle_call_tool(@callback_tool, _arguments, _ctx, _config) do
    record("same_server_callback")

    {:ok, [%{"type" => "text", "text" => "same-server callback complete"}], false}
  end

  def handle_call_tool(name, _arguments, _ctx, _config),
    do: {:error, -32_601, "Unknown tool: #{name}"}

  @impl true
  def handle_list_resources(_cursor, _ctx, _config) do
    {:ok,
     [
       %{
         "uri" => @resource_uri,
         "name" => "MCP Apps interoperability view",
         "mimeType" => MCP.Apps.mime_type(),
         "_meta" => resource_meta()
       }
     ], nil}
  end

  @impl true
  def handle_read_resource(@resource_uri, _ctx, _config) do
    record("resources_read")

    {:ok,
     [
       %{
         "uri" => @resource_uri,
         "mimeType" => MCP.Apps.mime_type(),
         "text" => view_html(),
         "_meta" => resource_meta()
       }
     ]}
  end

  def handle_read_resource(uri, _ctx, _config),
    do: {:error, -32_602, "Resource not found", %{"uri" => uri}}

  defp resource_meta do
    %{
      "ui" => %{
        "csp" => %{
          "connectDomains" => [],
          "resourceDomains" => [],
          "frameDomains" => [],
          "baseUriDomains" => []
        },
        "permissions" => %{},
        "prefersBorder" => true
      }
    }
  end

  defp view_html do
    """
    <!doctype html>
    <html lang="en">
      <head><meta charset="utf-8"><title>MCP Elixir Apps Interop</title></head>
      <body>
        <main id="interop-status">booting</main>
        <script>
          (() => {
            const target = window.parent;
            const status = document.getElementById("interop-status");
            let callbackSent = false;
            const send = message => target.postMessage(message, "*");

            window.addEventListener("message", event => {
              const message = event.data;
              if (!message || message.jsonrpc !== "2.0") return;

              if (message.id === "initialize") {
                send({jsonrpc: "2.0", method: "ui/notifications/initialized", params: {}});
                status.textContent = "view initialized";
              }

              if (message.method === "ui/notifications/tool-result" && !callbackSent) {
                callbackSent = true;
                send({
                  jsonrpc: "2.0",
                  id: "callback",
                  method: "tools/call",
                  params: {name: "apps_same_server_callback", arguments: {}}
                });
              }

              if (message.id === "callback" && message.result) {
                status.textContent = "same-server callback complete";
                document.body.dataset.interop = "complete";
              }
            });

            send({
              jsonrpc: "2.0",
              id: "initialize",
              method: "ui/initialize",
              params: {
                protocolVersion: "2026-01-26",
                appInfo: {name: "mcp-elixir-sdk-interop", version: "1.0.0"},
                appCapabilities: {}
              }
            });
          })();
        </script>
      </body>
    </html>
    """
  end

  defp record(event) do
    if path = System.get_env("MCP_APPS_INTEROP_EVENTS") do
      File.write!(path, event <> "\n", [:append])
    end
  end
end
