# Onboarding Guide: MCP Elixir SDK

> **Archived 1.x onboarding record.** The initialization/session lifecycle
> below is historical 1.x design material, not the current 2.0 implementation.
> Version 2.0 again supports the `2025-11-25` wire lifecycle through its
> isolated compatibility layer. New contributors must use the [current README](../README.md),
> [architecture](architecture.md), and
> [development tooling guide](dev-tooling.md) for SDK 2.0.

## For New AI Agents / Developers

This document provides everything needed to start implementing the MCP Elixir SDK library
(Hex package `mcp_elixir_sdk`; local directory still `/workspace/elixir_code/mcp_ex/`).

---

## 1. What Is This Project?

MCP Elixir SDK is an Elixir implementation of the [Model Context Protocol](https://modelcontextprotocol.io/) (MCP). MCP is an open standard (like LSP for code editors) that enables standardized communication between LLM applications and external tools/data sources.

The library provides:
- **MCP Client** — connects to MCP servers, discovers and calls tools, reads resources, uses prompts
- **MCP Server** — exposes tools, resources, and prompts to MCP clients
- **Pluggable transports** — stdio (subprocess) and Streamable HTTP (POST + SSE)

### Why It Exists

Any Elixir application (Phoenix apps, LiveView, CLI tools, Nerves devices) may want MCP capabilities. This is a standalone library with no ADK dependency.

The ADK integration is a thin adapter: `ADK.Tool.McpToolset` in `adk_ex` wraps `MCP.Client` as an `ADK.Tool.Toolset` implementation.

---

## 2. Key Resources

| Resource | Location |
|----------|----------|
| **This package** | `/workspace/elixir_code/mcp_ex/` |
| **MCP Spec (2025-11-25)** | https://modelcontextprotocol.io/specification/2025-11-25 |
| **TypeScript schema (source of truth)** | https://github.com/modelcontextprotocol/specification/blob/main/schema/2025-11-25/schema.ts |
| **Go SDK (primary reference)** | `/workspace/samples/mcp-go-sdk/` |
| **Python SDK** | `/workspace/samples/mcp-python-sdk/` |
| **Ruby SDK** | `/workspace/samples/mcp-ruby-sdk/` |
| **TypeScript SDK** | `/workspace/samples/mcp-typescript-sdk/` |
| **Conformance tests** | `/workspace/samples/mcp-conformance/` |
| **ADK package** | `/workspace/elixir_code/adk_ex/` |
| **ADK Ecto package** | `/workspace/elixir_code/adk_ex_ecto/` |
| **CLAUDE.md** | `/workspace/elixir_code/mcp_ex/CLAUDE.md` |
| **PRD** | `/workspace/elixir_code/mcp_ex/docs/prd.md` |
| **Architecture** | `/workspace/elixir_code/mcp_ex/docs/architecture.md` |
| **Implementation Plan** | `/workspace/elixir_code/mcp_ex/docs/implementation-plan.md` |

Clone reference SDKs before starting:
```bash
git clone https://github.com/modelcontextprotocol/go-sdk /workspace/samples/mcp-go-sdk
git clone https://github.com/modelcontextprotocol/python-sdk /workspace/samples/mcp-python-sdk
git clone https://github.com/modelcontextprotocol/ruby-sdk /workspace/samples/mcp-ruby-sdk
git clone https://github.com/modelcontextprotocol/typescript-sdk /workspace/samples/mcp-typescript-sdk
git clone https://github.com/modelcontextprotocol/conformance /workspace/samples/mcp-conformance
```

---

## 3. MCP Protocol Summary

### Three Phases

```
1. Initialization    Client → initialize request (capabilities, clientInfo, protocolVersion)
                     Server → initialize response (capabilities, serverInfo, protocolVersion)
                     Client → initialized notification
                     (No other requests except ping before this completes)

2. Operation         Bidirectional JSON-RPC 2.0 messages
                     Both sides respect negotiated capabilities

3. Shutdown          Transport-level disconnection
                     HTTP: DELETE request to session endpoint
```

### Roles

- **Host**: Application containing one or more MCP clients (e.g., Claude Desktop)
- **Client**: Maintains 1:1 stateful session with a server. Provides sampling, roots, elicitation.
- **Server**: Provides tools, resources, prompts. Can request sampling/elicitation from client.

### Server Features (server provides to client)

| Feature | Methods | Description |
|---------|---------|-------------|
| **Tools** | `tools/list`, `tools/call` | Functions the LLM can call. Model-controlled. |
| **Resources** | `resources/list`, `resources/read`, `resources/subscribe`, `resources/templates/list` | Data/context for the LLM. Application-controlled. |
| **Prompts** | `prompts/list`, `prompts/get` | Templates for user interactions. User-controlled. |
| **Logging** | `logging/setLevel`, `notifications/message` | Server sends log messages to client. |
| **Completions** | `completion/complete` | Argument auto-completion hints. |

### Client Features (client provides to server)

| Feature | Methods | Description |
|---------|---------|-------------|
| **Sampling** | `sampling/createMessage` | Server requests LLM completion via client. |
| **Roots** | `roots/list`, `notifications/roots/list_changed` | Client tells server about filesystem boundaries. |
| **Elicitation** | `elicitation/create` | Server requests user input via client (form or URL mode). |

### JSON-RPC 2.0 Message Types

```json
// Request (has id + method)
{"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}

// Response (has id + result/error)
{"jsonrpc": "2.0", "id": 1, "result": {"tools": [...]}}

// Error response
{"jsonrpc": "2.0", "id": 1, "error": {"code": -32601, "message": "Method not found"}}

// Notification (has method, NO id)
{"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}
```

Key rules:
- Requests MUST have an `id` (integer or string, never null)
- Notifications MUST NOT have an `id`
- `"jsonrpc": "2.0"` is always required
- IDs must be unique per session

---

## 4. Transports

### Stdio Transport

```
Client Process                          Server Subprocess
    |                                         |
    +-- Port.open({:spawn_executable, ...}) --+
    |                                         |
    +-- Write: JSON + "\n" to stdin --------->|
    |                                         |
    |<-------- Read: JSON + "\n" from stdout--+
    |                                         |
    +-- stderr: captured/logged, NOT protocol |
```

- Newline-delimited JSON-RPC messages
- Messages MUST NOT contain embedded newlines
- Server subprocess started via Erlang Port
- For server mode: read from stdin, write to stdout (we ARE the subprocess)

### Streamable HTTP Transport

```
Client                                   Server (Plug endpoint)
    |                                         |
    +-- POST JSON-RPC body ------------------>|
    |   Headers: Content-Type, Accept,        |
    |   MCP-Protocol-Version, MCP-Session-Id  |
    |                                         |
    |<-- Response: JSON or SSE stream --------+
    |   Header: MCP-Session-Id (on init)      |
    |                                         |
    +-- GET (optional, SSE listen) ---------->|
    |<-- Server-initiated msgs via SSE -------+
    |                                         |
    +-- DELETE (session close) -------------->|
```

Key details:
- POST sends one JSON-RPC message, response is `application/json` or `text/event-stream`
- SSE streams can include multiple server messages before the final response
- `MCP-Session-Id` header required after initialization (server generates it)
- `MCP-Protocol-Version: 2025-11-25` required on all HTTP requests
- SSE event IDs enable resumability via `Last-Event-ID` header
- Optional GET endpoint for receiving server-initiated messages

---

## 5. Planned Module Map

```
lib/mcp/
  # === Core Protocol ===
  protocol.ex                        # JSON-RPC 2.0 encoding/decoding
  protocol/
    types.ex                         # All MCP type structs
    messages.ex                      # Base Request/Response/Notification structs
    messages/                        # Method-specific message types
      initialize.ex                  # Initialize handshake types
      tools.ex                       # tools/list, tools/call types
      resources.ex                   # resources/* types
      prompts.ex                     # prompts/* types
      sampling.ex                    # sampling/createMessage types
      roots.ex                       # roots/list types
      elicitation.ex                 # elicitation/create types
      logging.ex                     # logging types
      completion.ex                  # completion types
      ping.ex                        # ping types
    capabilities.ex                  # ClientCapabilities, ServerCapabilities
    error.ex                         # Error codes + constructors

  # === Transport Layer ===
  transport.ex                       # Transport behaviour
  transport/
    stdio.ex                         # Port-based stdin/stdout transport
    sse.ex                           # SSE parsing/encoding utilities
    streamable_http/
      client.ex                      # HTTP POST + SSE client transport (Req)
      server.ex                      # HTTP POST + SSE server transport (Plug)

  # === Client ===
  client.ex                          # High-level client API (GenServer)

  # === Server ===
  server.ex                          # High-level server API (GenServer, async tool support)
  server/
    handler.ex                       # Behaviour for tool/resource/prompt handlers
    tool_context.ex                  # Context for async tool handlers (send notifications, make requests)
```

---

## 6. Elixir/OTP Patterns to Follow

### GenServer Per Connection
Each MCP client and server session is a GenServer. State includes transport, capabilities, pending requests, and an incrementing request ID counter.

### Transport as Separate Process
The transport (stdio Port, HTTP client) runs in its own process and sends decoded messages to the owning GenServer via `send(owner, {:mcp_message, decoded_map})`.

### Request/Response Matching
Outgoing requests store `{from, timeout_ref}` in `pending_requests` map keyed by ID. When a response arrives with a matching ID, `GenServer.reply/2` resolves the caller. Timeouts use `Process.send_after/3`.

### Handler Behaviour for Server
Server features use a behaviour (`MCP.Server.Handler`) with optional callbacks. The server auto-detects which capabilities to advertise based on which callbacks the handler module exports.

### Type Serialization
Internal types use snake_case Elixir structs. Wire format uses camelCase JSON maps. Each type module provides `to_map/1` (struct → wire) and `from_map/1` (wire → struct).

### Error Handling
JSON-RPC errors are always returned as `{:error, %MCP.Protocol.Error{code: ..., message: ...}}`. Protocol errors (parse, invalid request) use standard codes. Application errors use the error result format in responses.

---

## 7. Critical Protocol Rules

These are the most important constraints from the MCP spec. Violating any of these will cause conformance test failures.

1. **Initialization order is strict**: Client sends `initialize` request → server responds → client sends `initialized` notification. No other requests (except ping) allowed before this sequence completes.

2. **Capability gating**: Only use features the other side declared during initialization. If server didn't declare `tools`, don't send `tools/list`. If client didn't declare `sampling`, server can't send `sampling/createMessage`.

3. **JSON-RPC 2.0 compliance**: Every message needs `"jsonrpc": "2.0"`. Requests need unique IDs (integer or string, never null). Notifications must NOT have IDs.

4. **Stdio framing**: One JSON object per line. No embedded newlines in the JSON. Server stderr is not protocol.

5. **Streamable HTTP headers**: `MCP-Protocol-Version: 2025-11-25` on every request. `MCP-Session-Id` after initialization. `Accept: application/json, text/event-stream`.

6. **Protocol version negotiation**: Client sends desired version in initialize. Server responds with version it supports. If incompatible, client should disconnect.

7. **Tool annotations are untrusted**: Clients SHOULD NOT rely on tool annotations (readOnlyHint, destructiveHint, etc.) for security decisions unless the server is explicitly trusted.

8. **Sampling is bidirectional**: Server sends `sampling/createMessage` REQUEST to client (not the other way around). The client is the one that actually calls the LLM.

9. **Pagination is cursor-based**: List operations may include `nextCursor` in the result. To get more items, re-send the list request with `cursor` param set to that value.

10. **Structured content in tool results**: `tools/call` responses can include `structuredContent` (any JSON value) alongside the `content` array. The `content` array is for display; `structuredContent` is for programmatic use.

---

## 8. Reference SDK Patterns

### Go SDK (Primary Reference)
Located at `/workspace/samples/mcp-go-sdk/`. Well-structured, most complete.

Key files to study:
- `mcp/types.go` — All MCP type definitions
- `mcp/mcp.go` — JSON-RPC message types and method constants
- `mcp/client.go` + `mcp/client_session.go` — Client implementation
- `mcp/server.go` + `mcp/server_session.go` — Server implementation
- `mcp/stdio.go` — Stdio transport
- `mcp/streamable_http.go` — HTTP transport
- `mcp/transport.go` — Transport interface

Patterns to adapt:
- Go uses interfaces; Elixir uses behaviours
- Go uses channels; Elixir uses GenServer message passing
- Go uses context.Context for cancellation; Elixir uses process monitoring + timeouts
- Go's `ServerTool` bundles tool definition + handler; our Handler behaviour separates them

### Python SDK
Located at `/workspace/samples/mcp-python-sdk/`. Uses decorators and async/await.
- Good for understanding the protocol flow
- Decorator-based tool registration (`@server.tool()`)

### Ruby SDK
Located at `/workspace/samples/mcp-ruby-sdk/`. Built by Shopify, clean OOP patterns.
- Good for understanding the server handler pattern
- Uses blocks for tool handlers

---

## 9. Development Workflow

### Getting Started
```bash
cd /workspace/elixir_code/mcp_ex
mix deps.get
mix test
mix credo
mix dialyzer
```

### After Each Phase
```bash
mix test         # All tests pass
mix credo        # No issues
mix dialyzer     # No warnings
```

### Testing Patterns

**Unit tests with mock transport**:
```elixir
# Start client with mock transport that captures messages
{:ok, client} = MCP.Client.start_link(transport: {MCP.Test.MockTransport, []})

# Inject a response from the "server"
MCP.Test.MockTransport.inject(transport, %{
  "jsonrpc" => "2.0",
  "id" => 1,
  "result" => %{"tools" => []}
})

# Verify the client sent the right request
assert MCP.Test.MockTransport.last_sent(transport) == %{
  "jsonrpc" => "2.0",
  "id" => 1,
  "method" => "tools/list",
  "params" => %{}
}
```

**Integration tests with stdio** (our client talks to our server):
```elixir
# Start our server as a subprocess, connect our client to it
{:ok, client} = MCP.Client.connect("test",
  transport: {:stdio, command: "mix run --no-halt -e 'MCP.Server.run(...)'"}
)
```

**Use unique names** for GenServer registrations in async tests:
```elixir
name = :"client_#{System.unique_integer([:positive])}"
```

### Conformance Testing
Run against the official MCP conformance test suite (100% pass rate achieved):
```bash
# Start the conformance server adapter
mix run conformance/server_adapter.exs 3099 &

# Run server conformance tests
npx @modelcontextprotocol/conformance@latest test server --url http://localhost:3099/mcp

# Result: 30/30 scenarios, 40/40 checks (100%, Tier 1)
```

---

## 10. Common Gotchas

1. **camelCase vs snake_case**: MCP wire format uses camelCase (`inputSchema`, `nextCursor`, `listChanged`). Elixir code uses snake_case. Every type needs bidirectional conversion. Don't forget nested types.

2. **Notifications vs requests**: Notifications have NO `id` field. If you accidentally include an `id` in a notification, the other side may treat it as a request and try to respond.

3. **Capability check before use**: Before sending any feature-specific request, check that the other side declared that capability. For example, server must check `client_capabilities.sampling` before sending `sampling/createMessage`.

4. **Port buffering**: Erlang Ports may deliver partial lines. You MUST buffer incoming data and split on newlines. Don't assume each `{:data, data}` message from the Port contains exactly one JSON line.

5. **SSE parsing is stateful**: SSE events span multiple lines (`event:`, `data:`, `id:`, blank line). You need a stateful parser that buffers partial events across HTTP chunks.

6. **Session ID lifecycle**: For Streamable HTTP, the session ID is generated by the server during the initialize response. Client must include it in all subsequent requests. If the session ID is missing or wrong, server should reject the request.

7. **Initialize before everything**: The `initialize`/`initialized` handshake MUST complete before any feature requests. The only exception is `ping`, which works at any time.

8. **Tool result content is an array**: `tools/call` results contain a `content` field that is an ARRAY of content items (TextContent, ImageContent, etc.), not a single item.

9. **Structured content is optional**: `structuredContent` is a raw JSON value, not wrapped in Content types. In the SDK 2.0 model, absence is distinct from an explicitly present JSON null.

10. **Error responses have no result**: A JSON-RPC error response has `error` (with code + message + optional data) but NOT `result`. These are mutually exclusive.

11. **Server-initiated requests need response**: When a server sends `sampling/createMessage` or `elicitation/create` to the client, these are JSON-RPC requests (with IDs) that require a response. The client must reply.

12. **Timeout all requests**: Every outgoing request should have a timeout. Stale entries in `pending_requests` will leak memory and leave callers hanging.

---

## 11. Error Codes Reference

### Standard JSON-RPC Errors
| Code | Name | When |
|------|------|------|
| -32700 | Parse error | Invalid JSON |
| -32600 | Invalid request | Not valid JSON-RPC |
| -32601 | Method not found | Unknown method string |
| -32602 | Invalid params | Wrong parameters |
| -32603 | Internal error | Server internal error |

### MCP-Specific Errors
| Code | Name | When |
|------|------|------|
| -32002 | Resource not found | Unknown resource URI |
| -32042 | URL elicitation required | Server needs out-of-band user interaction |
| -1 | User rejected | User/host declined sampling or elicitation |

---

## 12. Relationship to ADK

MCP Elixir SDK is standalone — no ADK dependency. The ADK uses it via a thin adapter:

```
adk_ex                          mcp_elixir_sdk
├── ADK.Tool.Toolset behaviour  ├── MCP.Client
│   └── ADK.Tool.McpToolset ────┤   (wraps MCP.Client as Toolset)
│       name/1 → "mcp:server"  │   list_tools → ADK tool structs
│       tools/2 → MCP.Client   │   call_tool → ADK tool execution
```

The `McpToolset` adapter lives in `adk_ex`, not here. It:
1. Starts an `MCP.Client` connection during toolset initialization
2. Calls `MCP.Client.list_tools/1` in `tools/2` callback to get available tools
3. Converts MCP Tool structs to ADK Tool structs
4. Delegates `tools/call` to `MCP.Client.call_tool/3` when the LLM invokes a tool

---

## 13. Content Type Reference

Tools, resources, and prompts can return multiple content types:

| Type | JSON `type` field | Key Fields | Usage |
|------|-------------------|------------|-------|
| Text | `"text"` | `text` | Most common. Plain text or markdown. |
| Image | `"image"` | `data` (base64), `mimeType` | Visual content (PNG, JPEG, etc.) |
| Audio | `"audio"` | `data` (base64), `mimeType` | Audio content (WAV, MP3, etc.) |
| Resource | `"resource"` | `resource.uri`, `resource.text` or `resource.blob` | Embedded resource content |
| Resource Link | `"resource_link"` | `uri`, `name`, `mimeType` | Reference to a resource (not embedded) |

---

## 14. Capability Negotiation Reference

### Server Capabilities (declared in initialize response)
```elixir
%{
  tools: %{listChanged: true},           # Supports tools + change notifications
  resources: %{subscribe: true, listChanged: true},  # Supports resources + subscriptions
  prompts: %{listChanged: true},          # Supports prompts + change notifications
  logging: %{},                           # Supports logging
  completions: %{}                        # Supports auto-completion
}
```

### Client Capabilities (declared in initialize request)
```elixir
%{
  roots: %{listChanged: true},            # Supports roots + change notifications
  sampling: %{},                          # Supports LLM sampling
  elicitation: %{form: %{}, url: %{}}    # Supports form and URL elicitation
}
```

Each sub-map can be empty `%{}` (feature supported, no sub-features) or absent (feature not supported). Check presence of the key, not its contents, to determine if a feature is available.
