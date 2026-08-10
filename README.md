# MCP Elixir SDK

An OTP-native Elixir client and server SDK for the Model Context Protocol. The
unreleased 2.0 line supports stateful `2025-06-18` and `2025-11-25` plus
stateless `2026-07-28` over stdio/in-process and Streamable HTTP transports.

> `2.0.0-rc.1` is a release candidate. Its handler API is a breaking cutover from
> 1.x, while its wire protocol remains compatible with `2025-11-25` peers.

## What 2.0 provides

- Tri-version selection: clients prefer `2026-07-28`, then perform bounded
  fallback through `2025-11-25` and `2025-06-18` only for lifecycle/version
  incompatibility signals.
- Version-isolated lifecycles: 2026 requests use `server/discover` and
  per-request metadata; 2025 requests use initialize/initialized and a session.
- OTP ownership: clients and stdio connections are GenServers; long-lived
  subscription workers run under consumer-supplied supervisors.
- Tools, resources, prompts, completions, extensions, and MRTR input-required
  round trips.
- Streamable HTTP routing headers, including schema-directed `Mcp-Param-*`
  headers and a bounded schema index.
- Lossless JSON Schema 2020-12 maps and full JSON structured-content values.
- Bounded request deadlines, isolated resolver/notification callbacks, and no
  client-side result cache.
- Configurable HTTP and stdio security policies with gateway-hardened presets,
  bounded bodies/frames, redirects disabled, and process-tree cleanup.

The authoritative design package is in [`docs/sdk-2.0`](docs/sdk-2.0). The
implementation tracks the pinned official schema revision documented in
[`docs/adr/0003-2.0.0-conformance-scope.md`](docs/adr/0003-2.0.0-conformance-scope.md).

## Installation

No production installation coordinate is currently advertised. The package
metadata is prepared for `v2.0.0-rc.1`, but that tag and Hex release do not
exist until the branch-finishing and publication workflows complete. Until
then, use only the exact verified release commit reported with the candidate.

Streamable HTTP uses the optional `Req`, `Plug`, and `Bandit` dependencies. `Req`
is supported across `>= 0.5.0 and < 0.8.0`.

**Platform support: Unix only.** `erlexec`, which supervises stdio subprocesses in
process groups, is a required dependency whose NIF does not build on Windows, so
the package does not compile there.

## Client

```elixir
{:ok, client} =
  MCP.Client.start_link(
    transport:
      {MCP.Transport.StreamableHTTP.Client,
       url: "http://127.0.0.1:4000/mcp"},
    client_info: %{name: "my_client", version: "1.0.0"},
    client_capabilities: %{"elicitation" => %{}},
    on_input_required: fn requests ->
      Map.new(requests, fn {id, _request} ->
        {id, %{"action" => "accept", "content" => %{"approved" => true}}}
      end)
    end
  )

{:ok, discovery} = MCP.Client.connect(client)
{:ok, %{"tools" => tools}} = MCP.Client.list_tools(client)
{:ok, result} = MCP.Client.call_tool(client, "add", %{"a" => 20, "b" => 22})
:ok = MCP.Client.close(client)
```

`connect/2` prefers `server/discover`. If the peer requires a legacy lifecycle,
it tries `2025-11-25` and then `2025-06-18`, initializes a session, and sends
`notifications/initialized`. Pass either legacy version through
`protocol_version:` to start directly in that mode.
Each operation has one end-to-end deadline covering transport work, schema
refresh, and any MRTR resolver invocation. Cache hints are returned to the
caller but results are never cached by the SDK.

### Client subscriptions

Subscriptions are explicit processes, not lazy enumerables:

```elixir
{:ok, subscription_supervisor} =
  DynamicSupervisor.start_link(strategy: :one_for_one)

{:ok, client} =
  MCP.Client.start_link(
    transport: {MyTransport, []},
    subscription_supervisor: subscription_supervisor
  )

filter = %MCP.Protocol.Types.SubscriptionFilter{tools_list_changed: true}
{:ok, handle} = MCP.Client.listen_subscriptions(client, filter)
{:ok, acknowledgment} = MCP.Client.SubscriptionHandle.next(handle, 5_000)
:ok = MCP.Client.SubscriptionHandle.close(handle)
```

Each worker has a bounded FIFO queue (256 by default). Overflow, owner death,
or transport loss closes only that subscription.

## Server handler

Handler configuration is immutable after `init/1`. Put mutable state behind a
supervised process and store its pid or registered name in the launch config.
Every request callback receives `MCP.Server.ToolContext` before that config.

```elixir
defmodule MyApp.MCPHandler do
  @behaviour MCP.Server.Handler

  alias MCP.Server.ToolContext

  @impl true
  def init(opts), do: {:ok, %{store: Keyword.fetch!(opts, :store)}}

  @impl true
  def handle_list_tools(_cursor, %ToolContext{}, _config) do
    {:ok,
     [
       %{
         "name" => "add",
         "description" => "Adds two numbers",
         "inputSchema" => %{
           "$schema" => "https://json-schema.org/draft/2020-12/schema",
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

The callback forms are documented in `MCP.Server.Handler`. A handler may
return `{:input_required, requests_map, request_state}` from `handle_call_tool/4`;
the client resolves the requests and retries with a new JSON-RPC id.

### Stdio or in-process connection

```elixir
{:ok, connection} =
  MCP.Server.Connection.start_link(
    transport: {MCP.Transport.Stdio, []},
    handler: {MyApp.MCPHandler, store: MyApp.Store},
    server_info: %{name: "my_server", version: "1.0.0"}
  )
```

### Streamable HTTP

```elixir
plug =
  MCP.Transport.StreamableHTTP.Plug.new(
    server_mod: MyApp.MCPHandler,
    handler_opts: [store: MyApp.Store],
    server_opts: [
      server_info: %{name: "my_server", version: "1.0.0"},
      extensions: %{"com.example/audit" => %{"version" => 1}}
    ],
    enable_json_response: false,
    allowed_hosts: ["mcp.example.com"],
    allowed_origins: ["https://app.example.com"],
    legacy_endpoint_owner: MyAppWeb.Endpoint,
    tool_schemas: %{
      "add" => %{"type" => "object", "properties" => %{}}
    }
  )

{:ok, _bandit} = Bandit.start_link(plug: plug, port: 4000)
```

Place authentication Plugs before the MCP Plug. A dynamic `handler_opts`
factory may read authenticated `conn.assigns` and return an `:identity`; never
derive identity from raw headers or tool arguments.

Set `allowed_hosts:` to the canonical Phoenix endpoint host and
`allowed_origins:` to trusted browser origins. Origins include their effective
port, so a port-specific entry authorizes only that port. Loopback development
defaults accept arbitrary loopback listener ports. A legacy session fingerprints
its initialization principal and re-resolves authentication on every POST, GET, and DELETE;
presenting the session ID under another principal returns 403.

The same endpoint accepts both wire eras. Stateless 2026 POSTs have no session.
Legacy 2025 initialize responses mint `Mcp-Session-Id`; subsequent POST/GET
requests require it, server-to-client requests flow over GET SSE, and DELETE
terminates the session. A connection selects one era and cannot mix them.
Legacy session processes are owned by the SDK application supervisor, bounded
globally and per principal, and reclaimed by idle and absolute expiry.

HTTP server subscriptions additionally require a duplicate `Registry` and a
`DynamicSupervisor`. Pass both as `subscription_registry:` and
`subscription_supervisor:` and publish filtered events with
`MCP.Server.SubscriptionPublisher.publish/4`.

## Development and verification

```text
mix precommit

# Individual gates
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
mix docs
mix hex.build
```

The pinned official harness adapters and scenario ledger live in
[`conformance/README.md`](conformance/README.md). See
[`docs/dev-tooling.md`](docs/dev-tooling.md)
for the complete local and CI workflow.

## License

MIT — see [`LICENSE`](LICENSE).
