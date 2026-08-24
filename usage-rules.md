# MCP Elixir SDK — Usage Rules

> Condensed, executable guidance for developers and coding agents using the
> unreleased `mcp_elixir_sdk` 2.0 release candidate. The [README](README.md) and
> generated module documentation are the authoritative public references.

## Supported MCP revisions

The SDK supports stateless `2026-07-28` (preferred) and stateful
`2025-11-25` compatibility. Do not implement the two lifecycle models in
consumer code. `MCP.Client.connect/2` performs bounded protocol selection, and
the server transports isolate the selected lifecycle.

## Installation

There is not yet a published 2.0 tag or Hex package. For evaluation, pin an
immutable Git commit rather than a branch:

```elixir
def deps do
  [
    {:mcp_elixir_sdk,
     git: "https://github.com/jmagar/mcp-elixir-sdk.git",
     ref: "1349fd74e896b871438420762f289211923230ec"}
  ]
end
```

Streamable HTTP requires the optional `Req`, `Plug`, and `Bandit`
dependencies. Stdio is Unix-only because the required `erlexec` dependency
uses a NIF that does not build on Windows.

## Client

Always provide a transport and client identity, then call `connect/2` before
protocol operations:

```elixir
{:ok, client} =
  MCP.Client.start_link(
    transport:
      {MCP.Transport.StreamableHTTP.Client,
       url: "http://127.0.0.1:4000/mcp"},
    client_info: %{name: "my_app", version: "1.0.0"}
  )

with {:ok, _discovery} <- MCP.Client.connect(client),
     {:ok, %{"tools" => tools}} <- MCP.Client.list_tools(client),
     {:ok, result} <- MCP.Client.call_tool(client, "add", %{"a" => 20, "b" => 22}) do
  {tools, result}
end

:ok = MCP.Client.close(client)
```

Use `try/after` when a client is started for a bounded operation so cleanup is
not skipped after an exception. For supervision, start `MCP.Client` from your
own child specification and let the owning supervisor manage its lifecycle.

Common operations are:

| Function | Purpose |
|---|---|
| `connect/2` | Select and establish the supported protocol lifecycle |
| `list_tools/2`, `list_all_tools/2` | List one page or bounded all pages |
| `call_tool/4` | Call a tool with optional deadline, metadata, and input schema |
| `list_resources/2`, `read_resource/3` | Discover and read resources |
| `list_prompts/2`, `get_prompt/4` | Discover and render prompts |
| `complete/4` | Request argument or reference completion |
| `listen_subscriptions/3` | Open a consumer-supervised 2026 subscription |
| `close/1` | Close the transport and client process |

Captured stdio diagnostics are opt-in. Configure the stdio transport with
`security_policy: [stderr: :capture]` and pass `stderr_handler:` to the client;
the SDK never logs captured subprocess output automatically.

## Server handler

Implement `MCP.Server.Handler`. `init/1` returns immutable launch
configuration. Every request callback receives a request-scoped
`MCP.Server.ToolContext` immediately before that configuration:

```elixir
defmodule MyApp.MCPHandler do
  @behaviour MCP.Server.Handler

  alias MCP.Server.ToolContext

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_list_tools(_cursor, %ToolContext{}, _config) do
    {:ok,
     [
       %{
         "name" => "add",
         "description" => "Adds two numbers",
         "inputSchema" => %{
           "type" => "object",
           "properties" => %{
             "a" => %{"type" => "number"},
             "b" => %{"type" => "number"}
           },
           "required" => ["a", "b"]
         }
       }
     ], nil}
  end

  @impl true
  def handle_call_tool("add", %{"a" => a, "b" => b}, %ToolContext{}, _config) do
    {:ok, [%{"type" => "text", "text" => to_string(a + b)}]}
  end

  def handle_call_tool(name, _arguments, %ToolContext{}, _config) do
    {:error, -32_601, "Unknown tool: #{name}"}
  end
end
```

Callbacks cannot replace the launch configuration. Put mutable domain state
behind a supervised process and store only its pid or registered name in that
configuration. Never derive `ToolContext.identity` from tool arguments,
request metadata, or unverified headers.

The complete runnable handler is
[`examples/quickstart_server.exs`](examples/quickstart_server.exs), and its
public callback contract is exercised by the test suite. Run it as a stdio
server with:

```sh
mix run examples/quickstart_server.exs -- --stdio
```

## Starting a server

For stdio or an in-process transport, start `MCP.Server.Connection`:

```elixir
{:ok, connection} =
  MCP.Server.Connection.start_link(
    transport: {MCP.Transport.Stdio, mode: :server},
    handler: {MyApp.MCPHandler, []},
    server_info: %{name: "my_server", version: "1.0.0"}
  )
```

For Streamable HTTP, mount the SDK Plug after authentication:

```elixir
plug =
  MCP.Transport.StreamableHTTP.Plug.new(
    server_mod: MyApp.MCPHandler,
    handler_opts: [],
    server_opts: [server_info: %{name: "my_server", version: "1.0.0"}],
    allowed_hosts: ["mcp.example.com"],
    allowed_origins: ["https://app.example.com"]
  )

{:ok, _bandit} = Bandit.start_link(plug: plug, port: 4000)
```

An authenticated HTTP application may pass a `handler_opts` function that
reads a verified principal from `conn.assigns`. It must not trust raw identity
headers by itself. Use the gateway security policy and explicit host/origin
allowlists for production endpoints.

## Public entry points

| Module | Purpose |
|---|---|
| `MCP.Client` | High-level client lifecycle and operations |
| `MCP.Client.SubscriptionHandle` | Consume and close subscription streams |
| `MCP.Server.Handler` | Consumer server behavior |
| `MCP.Server.Connection` | Stdio and in-process server connection |
| `MCP.Server.ToolContext` | Request identity, metadata, and notification context |
| `MCP.Server.SubscriptionPublisher` | Publish filtered subscription events |
| `MCP.Transport.Stdio` | Unix stdio transport |
| `MCP.Transport.StreamableHTTP.Client` | Streamable HTTP client transport |
| `MCP.Transport.StreamableHTTP.Plug` | Plug-compatible HTTP server transport |
| `MCP.Protocol.*` | Protocol messages, types, capabilities, and revisions |

Use the high-level client and handler interfaces where possible. Access the
protocol modules directly only when implementing extensions, adapters, or a
custom transport.
