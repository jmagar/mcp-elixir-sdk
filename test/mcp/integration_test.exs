defmodule MCP.IntegrationTest do
  @moduledoc """
  MES-9 — stateless integration: `MCP.Client` ↔ `MCP.Server.Connection`
  in-process over `BridgeTransport`. No `initialize` handshake and no session:
  the client discovers via `server/discover`, stamps per-request `_meta`, and
  every request stands alone. Server→client input rides MRTR (the client's
  `:on_input_required` resolver), replacing the retired held-open
  sampling/elicitation path (D-B).
  """
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Server.Connection
  alias MCP.Server.ToolContext
  alias MCP.Test.{BridgeTransport, StatelessHandler}

  # --- Context-bearing handler (stateless: reads ctx, never args, for identity) ---

  defmodule IntegrationHandler do
    @behaviour MCP.Server.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_list_tools(_cursor, %ToolContext{}, _config) do
      tools = [
        %{
          "name" => "echo",
          "description" => "Echoes input",
          "inputSchema" => %{"type" => "object"}
        },
        %{
          "name" => "add",
          "description" => "Adds a and b",
          "inputSchema" => %{"type" => "object"}
        }
      ]

      {:ok, tools, nil}
    end

    @impl true
    def handle_call_tool("echo", %{"message" => msg}, %ToolContext{}, _config),
      do: {:ok, [%{"type" => "text", "text" => msg}]}

    def handle_call_tool("add", %{"a" => a, "b" => b}, %ToolContext{}, _config),
      do: {:ok, [%{"type" => "text", "text" => "#{a + b}"}]}

    def handle_call_tool("error_tool", _args, %ToolContext{}, _config),
      do: {:ok, [%{"type" => "text", "text" => "boom"}], true}

    # MRTR: ask for input on the first pass, complete on the retry.
    def handle_call_tool("needs_input", _args, %ToolContext{input: nil}, _config),
      do:
        {:input_required, %{"name" => %{"method" => "elicitation/create", "params" => %{}}},
         "rs-1"}

    def handle_call_tool("needs_input", _args, %ToolContext{input: %{responses: r}}, _config) do
      name = get_in(r || %{}, ["name", "name"]) || "?"
      {:ok, [%{"type" => "text", "text" => "hi #{name}"}]}
    end

    def handle_call_tool(name, _args, %ToolContext{}, _config),
      do: {:error, -32_601, "Unknown tool: #{name}"}

    @impl true
    def handle_list_resources(_cursor, %ToolContext{}, _config),
      do: {:ok, [%{"uri" => "file:///readme.txt", "name" => "readme"}], nil}

    @impl true
    def handle_read_resource("file:///readme.txt", %ToolContext{}, _config),
      do: {:ok, [%{"uri" => "file:///readme.txt", "text" => "Hello from MCP!"}]}

    def handle_read_resource(uri, %ToolContext{}, _config),
      do: {:error, -32_602, "Resource not found: #{uri}"}

    @impl true
    def handle_list_resource_templates(_cursor, %ToolContext{}, _config),
      do: {:ok, [%{"uriTemplate" => "file:///{path}", "name" => "File"}], nil}

    @impl true
    def handle_list_prompts(_cursor, %ToolContext{}, _config),
      do: {:ok, [%{"name" => "greeting", "description" => "A greeting"}], nil}

    @impl true
    def handle_get_prompt("greeting", _args, %ToolContext{}, _config) do
      {:ok,
       %{"messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "Hi!"}}]}}
    end

    def handle_get_prompt(name, _args, %ToolContext{}, _config),
      do: {:error, -32_601, "Unknown prompt: #{name}"}

    @impl true
    def handle_complete(_ref, _argument, %ToolContext{}, _config),
      do: {:ok, %{"values" => ["foo", "foobar"], "total" => 2}}
  end

  # --- Helpers ---

  defp start_pair(client_opts \\ []) do
    {client_t, server_t} = BridgeTransport.create_pair()

    {:ok, server} =
      Connection.start_link(
        transport: {BridgeTransport, pid: server_t},
        handler: {IntegrationHandler, []},
        server_info: %{name: "test-server", version: "1.0.0"}
      )

    {:ok, client} =
      Client.start_link(
        Keyword.merge(
          [
            transport: {BridgeTransport, pid: client_t},
            client_info: %{name: "test-client", version: "0.1.0"}
          ],
          client_opts
        )
      )

    %{client: client, server: server}
  end

  # --- Tests ---

  test "connect discovers server capabilities via server/discover (no handshake)" do
    %{client: client} = start_pair()
    {:ok, result} = Client.connect(client)

    assert result.server_info.name == "test-server"
    assert result.protocol_version == "2026-07-28"
    assert result.server_capabilities.tools != nil
    assert Client.status(client) == :ready
  end

  test "a raising stdio handler returns an internal error and the connection remains usable" do
    {client_transport, server_transport} = BridgeTransport.create_pair()

    server =
      start_supervised!(
        {Connection,
         transport: {BridgeTransport, pid: server_transport}, handler: {StatelessHandler, []}}
      )

    client =
      start_supervised!(
        {Client,
         transport: {BridgeTransport, pid: client_transport},
         client_info: %{name: "test-client", version: "1"}}
      )

    assert {:error, %{code: -32_603}} = Client.call_tool(client, "emit_then_raise")
    assert {:ok, result} = Client.call_tool(client, "whoami")
    assert hd(result["content"])["text"] == ""
    assert :sys.get_state(server)
  end

  test "tools: list, echo, add, isError, unknown" do
    %{client: client} = start_pair()
    {:ok, _} = Client.connect(client)

    {:ok, list} = Client.list_tools(client)
    assert Enum.map(list["tools"], & &1["name"]) |> Enum.sort() == ["add", "echo"]

    {:ok, echo} = Client.call_tool(client, "echo", %{"message" => "hello"})
    assert hd(echo["content"])["text"] == "hello"

    {:ok, add} = Client.call_tool(client, "add", %{"a" => 3, "b" => 4})
    assert hd(add["content"])["text"] == "7"

    {:ok, err} = Client.call_tool(client, "error_tool", %{})
    assert err["isError"] == true

    {:error, error} = Client.call_tool(client, "nope", %{})
    assert error.code == -32_601
  end

  test "resources: list, read, unknown, templates" do
    %{client: client} = start_pair()
    {:ok, _} = Client.connect(client)

    {:ok, list} = Client.list_resources(client)
    assert hd(list["resources"])["uri"] == "file:///readme.txt"

    {:ok, read} = Client.read_resource(client, "file:///readme.txt")
    assert hd(read["contents"])["text"] == "Hello from MCP!"

    {:error, error} = Client.read_resource(client, "file:///missing")
    assert error.code == -32_602

    {:ok, templates} = Client.list_resource_templates(client)
    assert length(templates["resourceTemplates"]) == 1
  end

  test "prompts: list, get, unknown" do
    %{client: client} = start_pair()
    {:ok, _} = Client.connect(client)

    {:ok, list} = Client.list_prompts(client)
    assert hd(list["prompts"])["name"] == "greeting"

    {:ok, get} = Client.get_prompt(client, "greeting")
    assert length(get["messages"]) == 1

    {:error, error} = Client.get_prompt(client, "unknown")
    assert error.code == -32_601
  end

  test "completion/complete round-trips" do
    %{client: client} = start_pair()
    {:ok, _} = Client.connect(client)

    {:ok, result} =
      Client.complete(client, %{"type" => "ref/prompt", "name" => "greeting"}, %{"name" => "x"})

    assert result["completion"]["values"] == ["foo", "foobar"]
  end

  test "MRTR: call_tool transparently completes an input-required round-trip" do
    %{client: client} =
      start_pair(on_input_required: fn _requests -> %{"name" => %{"name" => "Ada"}} end)

    {:ok, _} = Client.connect(client)

    {:ok, result} = Client.call_tool(client, "needs_input", %{})
    assert result["resultType"] == "complete"
    assert hd(result["content"])["text"] == "hi Ada"
  end

  test "pagination helpers return all items" do
    %{client: client} = start_pair()
    {:ok, _} = Client.connect(client)

    {:ok, tools} = Client.list_all_tools(client)
    assert length(tools) == 2
  end

  test "graceful close of client and server" do
    %{client: client, server: server} = start_pair()
    {:ok, _} = Client.connect(client)

    assert :ok = Client.close(client)
    assert :ok = Connection.close(server)
  end
end
