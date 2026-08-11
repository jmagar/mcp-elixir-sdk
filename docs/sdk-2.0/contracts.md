# MCP Elixir SDK 2.0 Boundary Contracts

**Status:** Normative 2.0 target; current implementation gaps are tracked in
[meta-plan.md](meta-plan.md)
**Related:** [specifications.md](specifications.md) · [types.md](types.md) ·
[runtime-models.md](runtime-models.md) · [meta-plan.md](meta-plan.md)

These contracts define observable boundaries. Internals may change without a
breaking release only when the wire behavior, callback/API result, ownership,
and failure semantics below remain intact.

## C1 — Transport behavior

Every transport implements the existing `MCP.Transport` behavior:

```elixir
@callback start_link(keyword()) :: GenServer.on_start()
@callback send_message(pid(), map()) :: :ok | {:error, term()}
@callback close(pid()) :: :ok | {:error, term()}
```

The transport owns framing and delivery, not protocol semantics. It sends
decoded maps to its owner as `{:mcp_message, map()}` and reports terminal loss
as `{:mcp_transport_closed, reason}`. Closing an already stopped process is
idempotent; unexpected close failures are returned rather than reported as
success.

For 2026 Streamable HTTP:

- Request/response traffic uses POST with JSON or SSE responses.
- `MCP-Protocol-Version` is `2026-07-28` and matches the request body's
  protocol-version metadata.
- Routing headers obey C2.
- No `Mcp-Session-Id`, session DELETE, or unsolicited GET notification stream
  exists.
- Only `subscriptions/listen` owns a long-lived notification response stream.

For `2025-11-25` Streamable HTTP, initialize mints
`Mcp-Session-Id`; later POST and GET
requests require it, GET carries queued server messages as SSE, and DELETE
closes the session. Handler configuration and the identity binding are created
at initialize; the identity factory is then re-evaluated on every POST, GET,
and DELETE and compared with the stored fingerprint before lookup/delivery.
The supervised manager applies endpoint/per-principal caps and idle/absolute
expiry. One endpoint may serve both eras, but one session or owner-based
connection may never mix them.
GET listener session expiry and retry exhaustion are reported to the owner as
`{:mcp_legacy_sse_failed, reason}` rather than silently ending delivery.

For stdio, each JSON-RPC object is one newline-delimited frame. Subscription
messages share the same channel and are correlated by request/subscription ID.

## C2 — HTTP routing headers

| Body | `Mcp-Method` | `Mcp-Name` |
| --- | --- | --- |
| Any JSON-RPC request with `method` | Exact `method` | Omitted unless defined below |
| `tools/call` | `tools/call` | `params.name` |
| `prompts/get` | `prompts/get` | `params.name` |
| `resources/read` | `resources/read` | `params.uri` |
| Response (no `method`) | Omitted | Omitted |

The table applies to requests. The 2026 core defines no client-to-server HTTP
notifications and leaves optional notification-POST routing headers undefined.

Every request POST also carries `MCP-Protocol-Version`. It exactly matches
`params._meta["io.modelcontextprotocol/protocolVersion"]`. Missing, malformed,
or mismatched headers return HTTP 400 plus `HeaderMismatch`; an internally
consistent but unsupported version returns HTTP 400 plus
`UnsupportedProtocolVersion` and the supported-version list.

The body is authoritative. A user-provided header must never create a mismatch.
The server returns HTTP 400 with MCP `HeaderMismatch` semantics when a required
header is missing, malformed, or disagrees with the body. Header names are
case-insensitive. Decoded string and boolean values are compared exactly;
integer custom-header values SHOULD be compared numerically.

`Mcp-Name` and custom parameter values use plain ASCII only when the value is
safe as an HTTP field value and has no surrounding whitespace. Otherwise the
UTF-8 bytes are Base64-encoded as `=?base64?{payload}?=`. A literal value that
already begins and ends with those sentinel markers is also encoded to avoid
ambiguity. Servers decode before comparing.

For `tools/call`, a property annotated in the selected tool schema as:

```json
{"x-mcp-header": "Region"}
```

mirrors the corresponding argument into `Mcp-Param-Region`. A missing or JSON
null value omits the header. A present value requires the header and decoded
agreement under the type-specific comparison above. Intermediaries forward or
ignore unrecognized custom headers; recognized malformed or mismatched values
are rejected.

The Streamable HTTP server receives recognized schemas through immutable
transport configuration: either a static `tool_name => input_schema` map or a
`(tool_name, authenticated_identity -> input_schema | nil)` resolver. The
resolver runs only after identity resolution and MUST agree with the selected
schema advertised by `tools/list`. Header validation MUST NOT invoke
`handle_list_tools/3` as an implicit, potentially paginated or side-effectful
catalog request.

An annotation is valid only when all of these conditions hold:

1. Its value is a non-empty HTTP `tchar` token with no controls or CR/LF.
2. Its value is case-insensitively unique within the input schema.
3. The annotated property type is `string`, `boolean`, or an `integer` in the
   inclusive range `-(2^53 - 1)..(2^53 - 1)`; `number` is forbidden.
4. The property path contains only successive `properties` members from the
   schema root. It never crosses `items`, composition, conditionals, or `$ref`.

An invalid annotation invalidates only that tool. An HTTP client excludes the
tool from `tools/list` and SHOULD warn with the tool name and reason. Strings
are encoded as-is, integers as decimal strings, and booleans as lowercase
`true`/`false` before safe-value encoding.

## C3 — Per-request metadata

Every client request carries these keys inside `params._meta`:

| Key | Requirement | Owner |
| --- | --- | --- |
| `io.modelcontextprotocol/protocolVersion` | MUST equal `2026-07-28` | SDK |
| `io.modelcontextprotocol/clientInfo` | SHOULD identify client software | Host configuration |
| `io.modelcontextprotocol/clientCapabilities` | MUST describe this request's client abilities | SDK + host configuration |
| `io.modelcontextprotocol/logLevel` | Optional and deprecated | Host configuration |
| `traceparent`, `tracestate`, `baggage` | Optional, preserved unchanged | Observability integration |

`server/discover` is subject to the same request metadata and version gate as
other methods. Missing required metadata returns Invalid Params (`-32602`); an
unsupported version returns `UnsupportedProtocolVersion` (`-32022`) with
`data.supported` and `data.requested`. HTTP header mismatch is handled
separately by C2 before dispatch.

Unknown `_meta` keys are preserved. The protocol layer must not convert remote
strings to atoms.

## C4 — Identity boundary

Identity is transport-authenticated context, not protocol input.

```text
HTTP auth pipeline -> handler_opts.(conn) -> ToolContext.identity -> handler
stdio launch opts  -> fixed identity      -> ToolContext.identity -> handler
```

- HTTP resolves identity independently for every request.
- A 2025 session stores an identity fingerprint, not a bearer authorization;
  every session-bound HTTP request must authenticate as the same principal or
  fail with 403 before dispatch.
- Stdio/in-process may resolve a launch-static identity once.
- HTTP clients reject redirects, retries, unsafe endpoint URLs, oversized
  finite bodies, oversized SSE events, and receive/request deadline overruns
  with structured transport errors before decoding.
- Stdio clients reject oversized or malformed/non-JSON-RPC stdout, keep stderr
  outside the protocol channel, and apply the configured environment and
  process-tree shutdown policy. Captured stderr is never logged automatically;
  high-level clients receive it only through an explicit `:stderr_handler`.
- `params`, tool `arguments`, `_meta`, and routing headers are never identity
  sources.
- `MCP.Server.Dispatch` only accepts a preconstructed `ToolContext`; it does not
  authenticate.
- A handler option factory that raises or returns a non-keyword value fails the
  request cleanly before handler invocation.
- Identity-dependent cacheable output must use private scope when `ttlMs > 0`.

## C5 — Stateless dispatch

The current dispatch implementation returns a handler-state element, but both
transport owners discard it. That shape is a migration artifact, not the 2.0
contract. [ADR-004](../adr/0004-immutable-handler-launch-configuration.md)
fixes the target contract as:

```elixir
dispatch(request_or_notification, %MCP.Server.ToolContext{}, config)
  :: {:reply, response_map}
   | :noreply
```

`config` is immutable request-independent configuration. `config.handler_state`
is the launch value returned by `handler.init/1`; it is passed to callbacks but
never replaced by callback output. Mutable consumer data belongs in a
separately supervised process referenced by that launch value. A
context-bearing handler callback is required for every identity-capable method.
The 2.0 path never falls back to a legacy callback arity.

The 2026 path rejects `initialize`. The client prefers `server/discover`, then
falls back to a 2025 initialize only when discovery is missing or the peer's
unsupported-version response (including an HTTP 400 carrying that JSON-RPC
error) advertises 2025. The fallback attempts the supported legacy revision,
`2025-11-25`, at most once
and bounded by the connect deadline. Explicit legacy configuration initializes
directly. An expired legacy HTTP session permits one reinitialize-and-retry;
the retry cannot recurse. Other errors never trigger fallback.

## C6 — Handler callbacks

Current identity-capable callbacks take `ToolContext` immediately before state:

```elixir
handle_list_tools(cursor, context, state)
handle_call_tool(name, arguments, context, state)
handle_list_resources(cursor, context, state)
handle_read_resource(uri, context, state)
handle_list_resource_templates(cursor, context, state)
handle_list_prompts(cursor, context, state)
handle_get_prompt(name, arguments, context, state)
handle_complete(ref, argument, context, state)
```

In the target API, that final argument is named `handler_config` and remains
immutable. Existing success/error tuple shapes lose their final replacement
state element. For example, list callbacks return
`{:ok, values, next_cursor}` and tool callbacks return `{:ok, content}`,
`{:ok, content, is_error}`, `{:input_required, requests, request_state}`, or
`{:error, code, message}`. S5 changes the behaviour and dispatch together so no
mixed stateful/stateless callback contract ships.

S2 will add a subscription authorization/acceptance callback. Its contract is:

```elixir
handle_listen_subscriptions(filter, context, handler_config)
  :: {:ok, honored_filter}
   | {:error, code, message}
```

The callback decides the honored subset but does not own transport streaming.
The runtime validates that `honored_filter` is a subset of the request and of
advertised capabilities.

## C7 — Subscription stream

Subscription lifecycle ordering is strict:

```text
listen request
  -> validate metadata and filter
  -> handler chooses honored subset
  -> acknowledgment (first correlated message)
  -> zero or more filtered notifications
  -> graceful result OR abrupt transport loss
```

Process ownership and queue policy are fixed by
[ADR-005](../adr/0005-consumer-owned-subscription-supervision.md).

- Subscription identity is the JSON-RPC request ID.
- Every correlated notification and the graceful result carries
  `_meta["io.modelcontextprotocol/subscriptionId"]`.
- A notification is emitted only when its family/URI is in the honored filter.
- Cancellation is scoped to one subscription and must not close the transport
  or other subscriptions.
- Stdio cancellation is `notifications/cancelled`. HTTP cancellation is the
  closure of that request's SSE response stream; the server stops work promptly,
  sends nothing further, and does not emit `notifications/cancelled`.
- Client and server workers have separately configurable bounded queues,
  defaulting to 256 events. Overflow terminates only that subscription and is
  observable locally as `:queue_overflow`; it is not a successful MCP result.
- Worker exit removes registry/broadcast membership before termination
  completes.
- HTTP servers SHOULD emit `X-Accel-Buffering: no` and comment keepalives every
  15 seconds by default. Clients ignore comment lines. `Last-Event-ID`
  resumption is unsupported.

## C8 — Capability and extension negotiation

Capabilities report what the endpoint can service now; they are not a wish
list. `extensions` and `experimental` are separate maps.

Client and server capability objects are explicitly open sets. Known fields
receive typed members; unknown capability names survive in a string-keyed
`extra` map and are re-emitted unchanged.

An extension map is `%{required(String.t()) => json_object()}` where every key
has a namespace prefix. Valid unknown settings round-trip exactly. Advertising
`io.modelcontextprotocol/tasks` does not add Tasks methods by itself.

Client extensions are sent in every request's client-capabilities metadata.
Server extensions are returned by `server/discover`. Neither side invents an
intersection: hosts inspect both declarations and decide whether to invoke an
extension.

## C9 — JSON Schema and JSON values

Wire JSON is represented without loss at schema-defined extensibility points:

```elixir
@type json_value :: nil | boolean() | number() | String.t() |
                    [json_value()] | %{required(String.t()) => json_value()}
```

- Tool input schema is a JSON object and has root `"type": "object"`.
- Tool output schema is any valid JSON Schema object.
- Structured content is any `json_value`, including `false`, `0`, `""`, `[]`,
  and `nil`. `:absent` is the local omission sentinel; encoders omit only that
  sentinel, never a valid JSON value.
- Unknown schema keywords are retained.
- Unknown `_meta`, request-param, result, and capability members are retained in
  string-keyed raw/extra maps. Closed protocol objects may reject unknown
  members.
- External references are data; the SDK does not fetch or dereference them.

## C10 — Cacheable results

Every cacheable result exposes `resultType`, `ttlMs`, and `cacheScope` according
to the final schema. Server default `{0, "public"}` means no-store.

Per [ADR-006](../adr/0006-no-client-result-cache-in-2.0.md), the 2.0 client
performs no result caching. It preserves these fields for hosts
but always sends the operation to the transport. Tests issue repeated identical
public and private calls and prove each reaches the server. Adding client result
caching later requires a new ADR that defines keys, identity partitioning,
invalidation, bounds, and unknown-scope behavior.

## C11 — Failure semantics

| Boundary failure | Observable result | Handler invoked? |
| --- | --- | ---: |
| Malformed JSON / JSON-RPC | Standard parse/invalid-request error | No |
| Routing header mismatch | HTTP 400 + MCP header-mismatch error | No |
| Required standard/custom header missing or malformed | HTTP 400 + MCP header-mismatch error | No |
| Missing/unsupported protocol version | HTTP 400 where applicable + `-32022` | No |
| Capability/method absent | Method-not-found | No |
| Missing required client capability | MCP `-32021` with required capabilities | No |
| Invalid params/filter/schema shape | Invalid Params (`-32602`) | No |
| Handler domain error | Handler-provided MCP error | Yes |
| Tool execution error intended for model | Successful result with `isError: true` | Yes |
| Transport closes with pending calls | `{:error, {:transport_closed, reason}}` | Maybe |
| Transport cleanup fails before close | `{:error, {:transport_closed, {:cleanup_failed, cleanup_reason, close_reason}}}`; `MCP.Client.transport_failure/1` returns `cleanup_reason` | Maybe |
| Client request timeout | `{:error, :timeout}` | Maybe |
| Subscription queue overflow | Subscription terminates; other work continues | Already established |
| MRTR/notification callback raises or times out | Operation/callback fails; client GenServer remains responsive | Maybe |

## C12 — Verification and release claims

No slice is complete from code review alone. Each requires:

1. A failing test demonstrating the missing behavior.
2. Focused tests passing after implementation.
3. The full suite passing.
4. Formatter and static checks passing, or a named toolchain blocker.
5. Relevant official conformance scenarios passing.
6. Evidence entered in [meta-plan.md](meta-plan.md).

A release conformance claim must be reproducible from a clean checkout and pin
the harness version. Skips are acceptable only when enumerated with an
in-scope/out-of-scope reason.

## Current implementation anchors

- Transport callbacks: [`transport.ex:27`](../../lib/mcp/transport.ex#L27)
- Per-request metadata parser: [`meta.ex:46`](../../lib/mcp/protocol/meta.ex#L46)
- Identity-bearing context:
  [`tool_context.ex:47`](../../lib/mcp/server/tool_context.ex#L47)
- Immutable config builder: [`config.ex:68`](../../lib/mcp/server/config.ex#L68)
- Dispatch result contract: [`dispatch.ex:55`](../../lib/mcp/server/dispatch.ex#L55)
- Routing header implementation:
  [`client.ex:191`](../../lib/mcp/transport/streamable_http/client.ex#L191)
