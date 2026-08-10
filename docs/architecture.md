# Architecture

MCP Elixir SDK 2.0 is an OTP-native dual-era implementation of MCP
`2025-11-25` and `2026-07-28`. Stateless 2026 dispatch remains sessionless;
legacy 2025 traffic uses an isolated initialize/session adapter. There is no
client-side result cache or mutable per-request handler configuration.

## Protocol selection

Clients prefer `2026-07-28` discovery and make one bounded fallback to the
`2025-11-25` initialize handshake when discovery is unavailable or the server
advertises only the legacy revision. Servers choose a mode on the first valid
request. A connection never changes modes.

The 2026 path validates per-request metadata and routes directly to stateless
dispatch. The 2025 path owns negotiated capabilities, session identity,
logging level, subscriptions, pending server-to-client requests, and SSE event
delivery. `MCP.Server.LegacyDispatch` adapts legacy envelopes to the immutable
handler contract without exposing injected compatibility metadata to handlers.

## Runtime topology

```text
Host application
├── MCP.Client (GenServer)
│   ├── transport process
│   ├── owned Task.Supervisor
│   └── optional consumer-supervised subscription workers
└── server transport
    ├── MCP.Server.Connection (stdio/in-process)
    │   └── optional consumer-supervised subscription workers
    └── MCP.Transport.StreamableHTTP.Plug (one dispatch per request)
        └── optional consumer-supervised subscription workers
```

The durable boundaries are:

- the transport owns bytes, HTTP/SSE framing, and transport cancellation;
- `MCP.Protocol` owns lossless message decoding and encoding;
- `MCP.Server.Dispatch` owns request metadata/version gates and method routing;
- the consumer handler owns domain behavior;
- consumer supervisors own long-lived subscription worker lifetimes.

## Request path

Every request is independently serviceable by any compatible server instance:

```text
JSON-RPC request
→ structural metadata validation
→ standard routing-header validation (HTTP)
→ authenticated identity resolution
→ schema-directed custom-header validation (HTTP tools/call)
→ protocol decode
→ ToolContext construction
→ immutable handler callback
→ result/error envelope
```

Required `_meta` fields are protocol version and client capabilities. Client
information is recommended but optional. An unsupported, internally consistent
version yields `-32022` with `data.supported` and `data.requested`; missing
required metadata yields `-32602`; a header/body disagreement yields `-32020`.

## Client

`MCP.Client` tracks discovered server information, monotonically increasing
request ids, pending operations, a bounded tool-schema LRU, callback tasks, and
subscriptions. Transport sends and user callbacks execute beneath a linked
`Task.Supervisor`, so blocking or crashing callbacks cannot block or terminate
the client GenServer.

An operation records its pending entry, timer, and absolute deadline before
transport I/O begins. The same deadline covers:

1. transport send and response;
2. one stale routing-schema refresh and retry;
3. every MRTR resolver round and retry.

The SDK exposes server cache hints but intentionally maintains no result cache.

## Server handler configuration

`MCP.Server.Config.build/2` calls `Handler.init/1` once. Its return value is
immutable launch configuration and is passed to each callback. Callback results
cannot replace it. Consumers needing mutable state store a supervised pid,
registered name, or other stable reference in the config.

`MCP.Server.ToolContext` is constructed for one request and carries the request
id, raw metadata, transport-authenticated identity, MRTR continuation input,
and a notification sink. Dispatch never derives identity from arguments or
metadata.

## Transports

`MCP.Transport` provides start, send, and close callbacks; transports may also
implement descriptor-aware sends and explicit subscription open/cancel hooks.

### Stdio and in-process

`MCP.Server.Connection` owns one transport endpoint and multiplexes independent
requests and long-lived subscriptions. It is not a protocol session: no
initialize state or negotiated identity exists. Stdio identity is fixed at
launch.

### Streamable HTTP

`MCP.Transport.StreamableHTTP.Plug` builds immutable server config at mount.
For 2026 it dispatches each POST independently and runs its `handler_opts`
factory per request after upstream authentication. For 2025 it runs the factory
at initialize, fingerprints that authenticated identity, and re-runs it on
every POST, GET, and DELETE before constant-time comparison with the session
binding. A supervised runtime manager owns the session process pair, endpoint
and per-principal capacity, idle/absolute expiry, and endpoint cleanup. HTTP
subscriptions retain only their individual response stream.

`MCP.Transport.StreamableHTTP.Client` emits `MCP-Protocol-Version`,
`Mcp-Method`, method-appropriate `Mcp-Name`, and validated `Mcp-Param-*`
headers. SSE response parsing supports interleaved notifications, final
results, comments, and chunk boundaries.

## Subscriptions

The client and server use distinct temporary worker types under
consumer-supplied `DynamicSupervisor`s. Server workers register in a duplicate
Registry and receive events through `MCP.Server.SubscriptionPublisher`.

Invariants:

- acknowledgment is the first stream message;
- honored filters are a subset of requested filters;
- every event and final result carries the subscription id;
- queues are bounded and FIFO;
- overflow, owner death, or disconnect affects only one subscription;
- HTTP close cancels the response stream; stdio close sends a scoped
  `notifications/cancelled`.

## MRTR

In 2026, server-to-client sampling, elicitation, and roots work is represented
as `InputRequiredResult`; the client resolves it outside the GenServer and
retries using MRTR. In 2025, these operations are independent correlated
JSON-RPC requests on the owner transport or legacy session GET SSE channel.

## Protocol representation

Known structs preserve unknown members in explicit `extra` maps where the
schema is extensible. Remote strings are never converted to atoms. Tool schemas
remain arbitrary JSON Schema 2020-12 objects; structured content accepts every
JSON value, preserving the distinction between absent and explicit `null`.

Capability `extensions` are validated string-keyed maps with namespaced
identifiers and object-valued settings. Advertising an extension never creates
an implementation for its methods.

## Verification

Unit, process, transport, and cross-transport integration tests cover protocol
types, ownership, deadlines, isolation, routing, MRTR, extensions, and
subscriptions. The pinned official conformance harness is an additional release
gate; exact commands and the scenario ledger are in `docs/dev-tooling.md` and
`conformance/scenarios.json`.
