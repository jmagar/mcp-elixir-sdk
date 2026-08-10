defmodule MCP.ExtensionsIntegrationTest do
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Protocol.Capabilities.ClientCapabilities
  alias MCP.Protocol.Messages.Request
  alias MCP.Server.{Config, Dispatch, ToolContext}
  alias MCP.Test.{MockTransport, StatelessHandler}

  @version "2026-07-28"

  test "client extensions and unknown capabilities ride every request metadata object" do
    capabilities = %ClientCapabilities{
      extensions: %{"com.example/ui" => %{"mimeTypes" => ["text/html"]}},
      extra: %{"vendorCapability" => %{"mode" => "fast"}}
    }

    client =
      start_supervised!(
        {Client, transport: {MockTransport, []}, client_capabilities: capabilities}
      )

    transport = Client.transport(client)
    task = Task.async(fn -> Client.list_tools(client) end)
    _ = :sys.get_state(client)
    request = await_request(transport)

    wire_capabilities =
      get_in(request, [
        "params",
        "_meta",
        "io.modelcontextprotocol/clientCapabilities"
      ])

    assert wire_capabilities["extensions"] == capabilities.extensions
    assert wire_capabilities["vendorCapability"] == %{"mode" => "fast"}

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => request["id"],
      "result" => %{"tools" => []}
    })

    assert {:ok, %{"tools" => []}} = Task.await(task)
  end

  test "server discovery advertises extensions but does not invent extension methods" do
    extensions = %{"io.modelcontextprotocol/tasks" => %{}, "com.example/widgets" => %{}}
    {:ok, config} = Config.build(StatelessHandler, extensions: extensions)
    context = %ToolContext{}

    discover = Request.new(1, "server/discover", request_params())
    assert {:reply, response} = Dispatch.dispatch(discover, context, config)

    wire_capabilities =
      response["result"]["capabilities"]
      |> Jason.encode!()
      |> Jason.decode!()

    assert wire_capabilities["extensions"] == extensions

    extension_request = Request.new(2, "tasks/get", request_params())
    assert {:reply, response} = Dispatch.dispatch(extension_request, context, config)
    assert response["error"]["code"] == -32_601
  end

  test "server configuration rejects invalid extension declarations before serving" do
    assert {:error, {:invalid_extension_identifier, "tasks"}} =
             Config.build(StatelessHandler, extensions: %{"tasks" => %{}})

    assert {:error, {:invalid_extension_settings, "com.example/tasks"}} =
             Config.build(StatelessHandler, extensions: %{"com.example/tasks" => []})
  end

  defp request_params do
    %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @version,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
    }
  end

  defp await_request(transport, attempts \\ 200)

  defp await_request(transport, attempts) when attempts > 0 do
    case MockTransport.last_sent(transport) do
      nil ->
        receive do
        after
          5 -> await_request(transport, attempts - 1)
        end

      request ->
        request
    end
  end

  defp await_request(_transport, 0), do: flunk("client did not send request")
end
