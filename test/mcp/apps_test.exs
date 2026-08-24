defmodule MCP.AppsTest do
  use ExUnit.Case, async: true

  alias MCP.Apps.{AppDefinition, Bridge, Limits, Validator}
  alias MCP.Protocol.Types.Content.ResourceLink
  alias MCP.Protocol.Types.{Resource, ResourceContents, ResourceTemplate}
  alias MCP.Test.MockTransport

  @uri "ui://weather/dashboard.html"
  @mime "text/html;profile=mcp-app"

  test "publishes and detects the stable extension capability" do
    {extension, settings} = MCP.Apps.capability()
    assert extension == "io.modelcontextprotocol/ui"
    assert settings == %{"mimeTypes" => [@mime]}
    assert MCP.Apps.negotiated?(%{extensions: %{extension => settings}})
    refute MCP.Apps.negotiated?(%{extensions: %{}})
    assert_raise ArgumentError, fn -> MCP.Apps.capability([]) end
  end

  test "validates canonical tool metadata and compatibility conflicts" do
    assert {:ok, %{resource_uri: @uri, visibility: ["model", "app"]}} =
             Validator.tool_meta(%{"ui" => %{"resourceUri" => @uri}})

    assert {:ok, %{resource_uri: @uri}} =
             Validator.tool_meta(%{"ui/resourceUri" => @uri})

    assert {:error, :conflicting_resource_uri} =
             Validator.tool_meta(%{
               "ui" => %{"resourceUri" => @uri},
               "ui/resourceUri" => "ui://other/view"
             })

    assert {:error, :resource_policy_on_tool} =
             Validator.tool_meta(%{"ui" => %{"resourceUri" => @uri, "csp" => %{}}})
  end

  test "validates bounded UI resource content and resource policy" do
    meta = %{
      "ui" => %{
        "csp" => %{
          "connectDomains" => ["https://api.example.com", "wss://events.example.com"],
          "resourceDomains" => ["https://*.example.com"]
        },
        "permissions" => %{"clipboardWrite" => %{}},
        "prefersBorder" => true
      }
    }

    assert {:ok, %{content: {:text, "<!doctype html>"}}} =
             Validator.resource(@uri, @mime, "<!doctype html>", nil, meta)

    assert {:error, :exactly_one_content_required} =
             Validator.resource(@uri, @mime, "html", "aGVsbG8=", nil)

    assert {:error, :invalid_csp_origin} =
             Validator.resource(@uri, @mime, "html", nil, %{
               "ui" => %{"csp" => %{"connectDomains" => ["https://user:pass@example.com"]}}
             })

    assert {:error, :resource_too_large} =
             Validator.resource(@uri, @mime, "12345", nil, nil, limits: [max_resource_bytes: 4])

    assert {:ok, %{uri: uri}} =
             Validator.resource(@uri <> "?token=secret", @mime, "html", nil, nil)

    assert uri == @uri <> "?token=secret"

    refute Validator.safe_uri(@uri <> "?token=secret") =~ "secret"
  end

  test "resource metadata content values override listing values" do
    assert {:ok, %{prefers_border: false, domain: "host.example"}} =
             Validator.merge_resource_meta(
               %{"ui" => %{"prefersBorder" => true, "domain" => "host.example"}},
               %{"ui" => %{"prefersBorder" => false}}
             )
  end

  test "builds a collision-safe immutable app catalog and model inventory" do
    definition = definition(["model", "app"])
    app_only = definition(["app"], "refresh", "ui://weather/refresh.html")

    assert {:ok, catalog} = AppDefinition.catalog([definition, app_only])
    assert Enum.map(AppDefinition.model_tools(catalog), & &1["name"]) == ["weather"]
    assert {:ok, %{"name" => "refresh"}} = AppDefinition.app_tool(catalog, "refresh")

    assert {:ok, %{"uri" => @uri}, %{ttl_ms: 0, cache_scope: "private"}} =
             AppDefinition.read_resource(catalog, @uri)

    assert {:error, :duplicate_app_definition} = AppDefinition.catalog([definition, definition])

    invalid_resource =
      Map.put(definition.resource, "_meta", %{
        "ui" => %{"permissions" => %{"camera" => true}}
      })

    assert {:error, :invalid_permissions} =
             AppDefinition.new(definition.tool, invalid_resource, definition.contents)
  end

  test "bridge codec enforces stable methods, byte bounds, and lifecycle order" do
    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "ui/initialize",
      "params" => %{
        "protocolVersion" => "2026-01-26",
        "appInfo" => %{"name" => "test", "version" => "1"},
        "appCapabilities" => %{}
      }
    }

    assert {:ok, encoded} = Bridge.encode(initialize)
    assert {:ok, ^initialize} = Bridge.decode(encoded)
    assert {:error, :message_too_large} = Bridge.decode(encoded, limits: [max_message_bytes: 8])
    assert {:error, :invalid_bridge_response} = Bridge.decode(%{"jsonrpc" => "2.0", "id" => 1})

    assert {:error, :metadata_too_deep} =
             Bridge.decode(
               %{
                 "jsonrpc" => "2.0",
                 "method" => "ui/message",
                 "id" => 2,
                 "params" => %{"a" => %{"b" => %{}}}
               },
               limits: [max_depth: 2]
             )

    state = %Bridge{}
    assert {:ok, state, [:reply_initialize]} = Bridge.transition(state, initialize)

    assert {:ok, state, []} =
             Bridge.transition(state, %{"method" => "ui/notifications/initialized"})

    assert {:ok, state, []} =
             Bridge.transition(state, %{"method" => "ui/notifications/tool-input"})

    assert {:ok, _state, []} =
             Bridge.transition(state, %{"method" => "ui/notifications/tool-result"})

    assert {:error, :invalid_lifecycle_transition} =
             Bridge.transition(%Bridge{}, %{"method" => "ui/notifications/tool-result"})

    assert {:error, :invalid_lifecycle_transition} =
             Bridge.transition(
               %{state | complete_input?: false},
               %{"method" => "ui/notifications/tool-result"}
             )
  end

  test "resource-family open objects preserve unknown JSON fields" do
    fixtures = [
      {Resource, %{"uri" => @uri, "name" => "view", "future" => %{"a" => 1}}},
      {ResourceContents, %{"uri" => @uri, "text" => "html", "future" => [1]}},
      {ResourceTemplate,
       %{"uriTemplate" => "ui://weather/{id}", "name" => "view", "future" => true}},
      {ResourceLink,
       %{"type" => "resource_link", "uri" => @uri, "name" => "view", "future" => nil}}
    ]

    Enum.each(fixtures, fn {module, fixture} ->
      decoded = module.from_map(fixture)
      assert decoded.extra == %{"future" => fixture["future"]}
      assert Jason.decode!(Jason.encode!(decoded))["future"] == fixture["future"]
    end)
  end

  test "limits reject invalid configuration" do
    assert %Limits{max_resource_bytes: 12} = Limits.new(max_resource_bytes: 12)
    assert_raise ArgumentError, fn -> Limits.new(max_depth: 0) end
  end

  test "client resolution performs one exact read and binds app calls to that client" do
    client =
      start_supervised!(
        {MCP.Client,
         transport: {MockTransport, []}, client_capabilities: MCP.Apps.client_capabilities()}
      )

    transport = MCP.Client.transport(client)
    tool = definition(["model", "app"]).tool
    assert {:error, :apps_not_negotiated} = MCP.Apps.Client.resolve(client, tool)
    assert MockTransport.sent_messages(transport) == []

    connect = Task.async(fn -> MCP.Client.connect(client) end)
    request = await_request(transport, 1)
    assert request["method"] == "server/discover"

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => request["id"],
      "result" => %{
        "supportedVersions" => ["2026-07-28"],
        "capabilities" => %{"extensions" => MCP.Apps.extensions()},
        "resultType" => "complete",
        "ttlMs" => 0,
        "cacheScope" => "public",
        "_meta" => %{
          "io.modelcontextprotocol/serverInfo" => %{"name" => "apps", "version" => "1"}
        }
      }
    })

    assert {:ok, _result} = Task.await(connect)

    resolve = Task.async(fn -> MCP.Apps.Client.resolve(client, tool) end)

    request = await_request(transport, 2)
    assert request["method"] == "resources/read"
    assert request["params"]["uri"] == @uri

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => request["id"],
      "result" => %{
        "contents" => [
          %{"uri" => @uri, "mimeType" => @mime, "text" => "<!doctype html>"}
        ]
      }
    })

    assert {:ok, app} = Task.await(resolve)
    assert {:text, "<!doctype html>"} = app.content
    assert length(MockTransport.sent_messages(transport)) == 2

    call = Task.async(fn -> MCP.Apps.Client.call_tool(app, %{}) end)
    request = await_request(transport, 3)
    assert request["method"] == "tools/call"

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => request["id"],
      "result" => %{"content" => [%{"type" => "text", "text" => "sunny"}]}
    })

    assert {:ok, %{"content" => [%{"text" => "sunny"}]}} = Task.await(call)
  end

  defp definition(visibility, name \\ "weather", uri \\ @uri) do
    tool = %{
      "name" => name,
      "inputSchema" => %{"type" => "object"},
      "_meta" => %{"ui" => %{"resourceUri" => uri, "visibility" => visibility}}
    }

    resource = %{"uri" => uri, "name" => name, "mimeType" => @mime}
    contents = %{"uri" => uri, "mimeType" => @mime, "text" => "<!doctype html>"}
    {:ok, definition} = AppDefinition.new(tool, resource, contents)
    definition
  end

  defp await_request(transport, count) do
    assert {:ok, messages} = MockTransport.await_sent(transport, count)
    List.last(messages)
  end
end
