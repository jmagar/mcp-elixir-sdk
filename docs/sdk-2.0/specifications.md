# MCP Elixir SDK 2.0 Specifications

**Status:** Active engineering specification
**Target:** MCP core `2026-07-28` and `2025-11-25`, client and server
**Baseline:** `2.0.0-dev.1` at `2b34b32`
**Progress source:** [meta-plan.md](meta-plan.md)

This document defines what the 2.0 SDK must do. It is intentionally narrower
than the historical PRD: it covers the six slices required to turn the current
stateless-core implementation into a releasable SDK. Boundary rules live in
[contracts.md](contracts.md), data shapes in [types.md](types.md), and OTP
lifecycle design in [runtime-models.md](runtime-models.md).

Normative words (`MUST`, `SHOULD`, `MAY`) are used deliberately. A planned
requirement is not an implementation claim; current status is recorded only in
the meta-plan.

## Scope

The 2.0 release targets the complete MCP `2026-07-28` **core** specification on
both client and server sides and full wire compatibility with the
`2025-11-25` core. It excludes the authorization profile and the
extension-track implementations themselves. The core extensions-negotiation
surface remains in scope because clients and servers must be able to advertise
extension identifiers and settings even when this SDK does not implement those
extensions.

The following are deferred from 2.0:

- OAuth 2.1 authorization-profile implementation.
- Tasks, MCP Apps, and other extension-specific methods.
- Persistence, job execution, databases, or an Ecto model layer.

## System invariants

Every slice preserves these invariants:

1. Every 2026 request, including `server/discover`, is self-describing through
   `_meta` and can be served by any instance; 2025 sessions remain affine.
2. `server/discover` is supported, but a client is not required to call it
   before another method.
3. Authenticated identity comes from the transport pipeline and is never read
   from model-controlled request arguments.
4. Streamable HTTP sends no `Mcp-Session-Id` for 2026. For 2025 it requires a
   session ID after initialize, revalidates the authenticated principal on
   every session request, and supports GET SSE plus session DELETE.
5. 2026 server-to-client input uses MRTR; 2025 uses correlated independent
   JSON-RPC requests over its connection or session SSE channel.
6. Unknown fields survive decode/encode only at schema-defined extensibility
   points: `_meta`, request params, result and capability objects, JSON Schema
   values, and extension settings. Closed protocol objects may reject unknown
   members.
7. A conformance claim names its protocol version, client/server denominator,
   harness version, exclusions, and skipped checks.

## Slice map

| Slice | Deliverable | Completion condition |
| --- | --- | --- |
| S1 | Streamable HTTP routing and parameter headers | S1a emits standard headers; S1b, after S4a lossless tool schemas, validates and emits custom headers; server validation and official conformance checks pass |
| S2 | Unified subscriptions | Typed `subscriptions/listen`, server stream lifecycle, client consumption, cancellation, and both transports pass tests |
| S3 | Extensions negotiation | Client and server capability models preserve validated extension maps through discovery and requests |
| S4 | JSON Schema 2020-12 | Tool schemas and structured results preserve the full permitted JSON value space without narrowing |
| S5 | Complete client/server wiring and conformance | Client exposes S2-S4, deliberately performs no result caching in 2.0, completes lifecycle/handler migrations, and all in-scope scenarios pass |
| S6 | Release hardening | Dependencies, static analysis, docs, package contents, and release claims are verified from the built artifact |
| S7 | Dual-era compatibility correction | Client fallback, server mode isolation, legacy sessions and callbacks, cross-transport tests, and both version matrices pass |

## S7 — Dual protocol-era compatibility

- Clients MUST prefer `2026-07-28` and make at most one fallback to
  `2025-11-25` when discovery is unavailable or the server advertises it.
- Explicit `protocol_version: "2025-11-25"` MUST initialize directly.
- A server connection/session MUST select exactly one protocol era and reject
  mixed-era traffic.
- Legacy HTTP MUST implement initialize/initialized, `Mcp-Session-Id`, POST,
  GET SSE server messages, and DELETE cleanup.
- Legacy HTTP sessions MUST be supervised, principal-bound, capacity-limited,
  and reclaimed by idle/absolute expiry. Failed initialize MUST NOT publish or
  retain a session.
- A current HTTP client MUST treat a conforming HTTP 400 unsupported-version
  JSON-RPC response as eligible for its single fallback, and MUST perform one
  bounded reinitialization after an expired-session HTTP 404.
- Legacy server/client surfaces MUST cover ping, roots, sampling, elicitation,
  resource subscriptions, logging, progress, and list-change notifications.
- Both peers MUST reject unnegotiated server-request capabilities, bound
  callback concurrency/deadlines, and preserve the selected protocol mode
  across notifications.
- Compatibility metadata injected by an internal adapter MUST NOT be visible to
  consumer handlers or emitted to legacy peers.

## S1 — Streamable HTTP routing headers

### Requirements

- Every outgoing HTTP JSON-RPC **request** MUST include `Mcp-Method` with the
  exact body method. The 2026 core defines no client-to-server HTTP
  notifications and does not define routing-header requirements for optional
  notification POSTs; the SDK MUST NOT claim such POSTs are conformant core
  traffic.
- Every outgoing HTTP JSON-RPC request MUST include `MCP-Protocol-Version`, and
  its value MUST equal request `_meta["io.modelcontextprotocol/protocolVersion"]`.
- `tools/call` and `prompts/get` MUST include `Mcp-Name` from `params.name`.
- `resources/read` MUST include `Mcp-Name` from `params.uri`.
- Methods without a defined routing target MUST omit `Mcp-Name`.
- `Mcp-Name` MUST use the specification's `=?base64?...?=` sentinel encoding
  when its UTF-8 value is not safe plain ASCII, has leading/trailing whitespace,
  or already matches the sentinel pattern.
- For `tools/call`, properties annotated with `x-mcp-header` in the selected
  tool's `inputSchema` MUST be mirrored into `Mcp-Param-{Name}` headers using
  the same safe-value encoding rules. Missing/null arguments omit the header.
- An `x-mcp-header` annotation is valid only when its value is non-empty, is a
  legal HTTP `tchar` token without control characters, and is case-insensitively
  unique within the tool schema. It may annotate only `string`, `boolean`, or
  JavaScript-safe `integer` properties in the inclusive range
  `-(2^53 - 1)..(2^53 - 1)`, reached from the root solely through `properties`;
  it MUST NOT appear below arrays, composition/conditional keywords, or `$ref`.
  `number` is forbidden.
- The client MUST exclude a tool with any invalid `x-mcp-header` annotation from
  the decoded `tools/list` result and SHOULD log the tool name and stable
  rejection reason. One invalid tool MUST NOT discard valid sibling tools.
- String values are used as-is before safe-value encoding, integers use decimal
  representation, and booleans use lowercase `true` or `false`. Servers compare
  string/boolean values exactly and SHOULD compare integer values numerically.
- The high-level client owns a bounded tool-schema index populated by successful
  `tools/list` results. Its configurable maximum defaults to 1,024 tools and
  eviction is least-recently-used. A host may also supply the schema explicitly
  for a call. On `HeaderMismatch` caused by a recognized custom header, the
  client refreshes `tools/list` and retries the call at most once; it never
  creates an unbounded hidden catalog in the transport.
- User-supplied extra headers remain supported. The SDK-generated routing
  values are authoritative; the final implementation MUST reject or prevent an
  extra-header override that would make headers disagree with the body.
- JSON-RPC responses, which have no `method`, MUST not acquire routing headers.
- A server MUST reject a missing, undecodable, or mismatched required
  standard/custom header with HTTP 400 and MCP `HeaderMismatch` (`-32020`). An
  unsupported protocol value instead returns HTTP 400 with
  `UnsupportedProtocolVersion` (`-32022`) and the supported versions.

### Acceptance

- Tests exercise a real Bandit endpoint and inspect received headers.
- Unit/integration coverage includes `tools/list`, `tools/call`, `prompts/get`,
  and `resources/read`.
- Encoding tests cover non-ASCII, control characters, surrounding whitespace,
  and literal sentinel-shaped values.
- Custom-header tests cover nested property paths, missing/null values, type
  conversion, safe integer bounds, empty/invalid/duplicate names, forbidden
  schema locations, per-tool rejection, LRU bounds, and one-shot stale-schema
  refresh/retry behavior.
- Server tests cover each required header missing, malformed, and mismatched.
- Protocol-version tests cover header/body mismatch separately from an
  unsupported but internally consistent version.
- The official `http-standard-headers` client scenario for `2026-07-28` passes.
- All other in-scope SEP-2243 client/server scenarios pass.
- Existing tests remain green.

### Retrospective implementation record

S1a and S1b.1 were implemented test-first in the current working tree. S1a
added standard routing-header emission and the pinned official conformance
scenario. S1b.1 added safe `Mcp-Name` encoding/decoding, body-authoritative
protocol headers, case-insensitive reserved-header collision rejection, strict
standard-header validation, HTTP 400 propagation for unsupported versions, and
routing-header-free response acknowledgment. Exact red/green and verification
evidence is kept in [meta-plan.md](meta-plan.md).

S1b.2 was committed and pushed as `332235c`; its post-commit adversarial
remediation is verified locally. It provides shared
`x-mcp-header` validation, invalid-tool filtering,
schema-driven `Mcp-Param-*` headers, the bounded client index, explicit
per-call schemas, server enforcement, and one-shot refresh/retry behavior. Its
delivery was split at the tool-schema boundary:

1. **S1b.1, complete locally:** safe standard routing headers and collision
   protection.
2. **S4a:** lossless `Tool.inputSchema` representation and round trips.
3. **S1b.2, committed after S4a:** `x-mcp-header` validation,
   invalid-tool filtering, bounded schema indexing, `Mcp-Param-*` emission,
   server enforcement, and one-shot refresh/retry.

## S2 — Unified `subscriptions/listen`

The final schema replaces the legacy `resources/subscribe`,
`resources/unsubscribe`, and unsolicited HTTP GET notification channel with one
long-lived `subscriptions/listen` request.

### Wire requirements

The request params MUST contain a `notifications` filter with only these core
fields:

```json
{
  "notifications": {
    "toolsListChanged": true,
    "promptsListChanged": true,
    "resourcesListChanged": true,
    "resourceSubscriptions": ["file:///guide.md"]
  }
}
```

- Every field is opt-in. A server MUST NOT send a notification family that was
  not requested.
- The first message for the subscription MUST be
  `notifications/subscriptions/acknowledged` and MUST report the honored subset.
- Every subscription notification MUST carry
  `_meta["io.modelcontextprotocol/subscriptionId"]` equal to the listen request
  ID.
- Graceful closure MUST return a `SubscriptionsListenResult` whose `_meta`
  contains the same subscription ID and whose `resultType` is `complete`.
- Abrupt transport loss produces no synthetic successful result.
- On stdio, cancellation uses `notifications/cancelled` referencing the listen
  request ID. On HTTP, closing the subscription's SSE response stream MUST
  cancel that request; the server SHOULD stop its work promptly and MUST send
  no further messages. HTTP MUST NOT send `notifications/cancelled`.
- The stream MUST NOT carry sampling, elicitation, or roots requests; those use
  MRTR.
- HTTP subscription responses SHOULD send `X-Accel-Buffering: no`. Servers
  SHOULD emit configurable SSE comment keepalives (default interval: 15
  seconds); clients MUST ignore all SSE comment lines. `Last-Event-ID` resumption
  is unsupported and MUST NOT be advertised or attempted.

### SDK requirements

- Add typed request, filter, acknowledgment, and result values described in
  [types.md](types.md).
- Add `listen_subscriptions/2`, returning an explicit subscription handle with
  bounded `next/2` consumption and idempotent `close/1`; do not expose a lazy
  enumerable that hides process ownership.
- Add a server handler seam for deciding the honored subset and an internal
  broadcaster that enforces the filter before emission.
- Remove legacy subscription capability detection from the 2.0 path rather than
  silently invoking legacy callbacks.
- Require a consumer-supplied named `DynamicSupervisor` (or pid) when
  subscriptions are enabled. Client-consumer workers and server-stream workers
  are distinct child types; one subscriber failure cannot terminate unrelated
  requests.
- Both worker types default to a 256-event queue, configurable to a positive
  integer. Overflow closes only that subscription, records `:queue_overflow`
  locally, and is never represented as a synthetic successful MCP result.

### Acceptance

- Contract tests cover acknowledgment-first ordering, filtering, correlation,
  cancellation, graceful closure, abrupt closure, and interleaved stdio
  subscriptions.
- HTTP and stdio end-to-end tests use `start_supervised!/1` and monitors rather
  than sleeps.
- HTTP tests cover response-stream disconnect cancellation, proxy-buffering
  header, keepalive comments, ignored comments, and rejected resumption.
- Back-pressure tests prove queue bounds and sibling isolation on overflow.
- Official subscription scenarios pass on both client and server sides.

## S3 — Extensions negotiation

### Requirements

- `ClientCapabilities` and `ServerCapabilities` MUST expose an `extensions`
  map distinct from `experimental`.
- Each extension key MUST have a mandatory namespace prefix and obey MCP `_meta`
  key naming rules.
- Each extension value MUST be a JSON object. Scalars, arrays, and null are
  invalid settings values.
- Unknown valid extension identifiers and settings MUST round-trip without
  atom creation or key rewriting.
- Discovery MUST return server extensions; every client request's capabilities
  metadata MUST carry client extensions.
- Extension advertisement MUST NOT imply implementation of extension methods.
  Calling an unimplemented extension method still yields method-not-found.

### Acceptance

- Encode/decode property tests cover multiple unknown extension identifiers,
  empty settings, and nested JSON settings.
- Invalid names and non-object values fail at the public construction or
  decoding boundary with a stable error.
- Discovery and normal request integration tests prove server and client
  propagation independently.

## S4 — JSON Schema 2020-12

S4a (lossless tool-schema representation and `x-mcp-header` annotation
preservation) is an entry dependency for S1b. The rest of S4 does not depend on
S1b and may proceed in parallel once S4a is stable.

### Requirements

- `Tool.inputSchema` MUST preserve arbitrary JSON Schema 2020-12 keywords while
  requiring an object root (`"type": "object"`).
- `Tool.outputSchema` MUST be a JSON object, matching the pinned MCP wire type,
  while preserving arbitrary JSON Schema 2020-12 object keywords unchanged.
- `structuredContent` MAY be any JSON value: object, array, string, number,
  boolean, or null.
- Public structs MUST represent an absent `structuredContent` member as
  `:absent`; `nil` represents a present JSON null. Encoders omit only
  `:absent`.
- `$schema`, `$ref`, `$defs`, composition, and conditional keywords MUST survive
  round trips unchanged.
- The SDK MUST NOT automatically dereference external `$ref` values.
- If validation is offered, it MUST be opt-in, bounded by depth/time/size, and
  must not become a mandatory runtime dependency for pass-through use.

### Acceptance

- Fixtures cover `$defs`/`$ref`, `oneOf`, `anyOf`, `allOf`, conditionals,
  boolean schemas where permitted, and every `structuredContent` JSON kind.
- Tests demonstrate that unknown schema keywords survive encode/decode.
- Official JSON Schema 2020-12 scenarios pass.

## S5 — Client wiring and complete conformance

### Requirements

- Public client APIs expose subscriptions and preserve extension capabilities
  and full JSON values introduced by S2-S4.
- The client MUST register pending state and start its configured timeout before
  transport I/O. The timeout bounds transmission, response waiting, and MRTR
  retries as one operation; late transport results cannot create orphaned
  pending entries.
- Function-based notification and MRTR input callbacks MUST execute in
  supervised tasks, never in the client GenServer. Callback exceptions,
  timeouts, cancellation, and late results have deterministic tests.
- Handler state produced by `init/1` is immutable launch configuration. The 2.0
  handler API returns results without a replacement state; mutable consumer
  data belongs in separately supervised processes referenced by launch
  configuration. Dispatch and both transport owners MUST enforce this contract.
- Client-side parsing MUST distinguish a complete result from
  `input_required`; existing MRTR retry behavior must remain bounded and
  cancellation-aware.
- The 2.0 client does not cache MCP results. It preserves and exposes `ttlMs`
  and `cacheScope` but always performs the requested operation. Tests MUST prove
  repeated calls reach the transport and no identity-sensitive result is
  replayed. A later cache would require a separate ADR and release contract.
- Trace-context `_meta` MUST be preserved even if the SDK does not create
  tracing spans.
- Every in-scope official client and server scenario MUST be mapped to an
  adapter entry or explicitly marked not applicable with a specification
  reason.

### Acceptance

- The harness version is pinned, not `latest`.
- A machine-readable scenario ledger records pass/fail/skip and the reason for
  every skip.
- Client and server suites pass all in-scope core checks for `2026-07-28`.
- The suite runs in CI from a clean checkout.

## S6 — Release hardening

### Requirements

- Resolve locked dependency security advisories or record an approved,
  time-bounded exception for each remaining advisory.
- Make full-project formatter, tests, Credo, Dialyzer, and conformance commands
  reliable on the supported Elixir/OTP matrix.
- Rewrite stale 1.x/`2025-11-25` README, HexDocs, examples, and package metadata.
- Ensure the package includes the five engineering documents or intentionally
  selects a documented public subset.
- Verify version, links, files, docs, and claims from `mix hex.build` output,
  not only from the working tree.
- Publishing and tagging remain an explicit owner action after all gates pass.

### Acceptance

- Clean-checkout verification passes on every supported runtime.
- `mix hex.build` contains no stale protocol claims or local-only paths.
- Release notes state: protocol version, core-only scope, authorization and
  extension exclusions, harness version, and conformance totals.
- The commit/tag/package checksums and CI run are added to the evidence ledger.

## Authoritative external sources

- [MCP `2026-07-28` schema](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/5f5440bb26a62e2cf3440b92da5a667efa03b267/schema/2026-07-28/schema.ts)
- [Pinned Streamable HTTP transport](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/5f5440bb26a62e2cf3440b92da5a667efa03b267/docs/specification/2026-07-28/basic/transports/streamable-http.mdx)
- [SEP-2106: JSON Schema 2020-12](https://modelcontextprotocol.io/seps/2106-json-schema-2020-12)
- [ADR-003: 2.0 conformance scope](../adr/0003-2.0.0-conformance-scope.md)
- [ADR-004: immutable handler launch configuration](../adr/0004-immutable-handler-launch-configuration.md)
- [ADR-005: consumer-owned subscription supervision](../adr/0005-consumer-owned-subscription-supervision.md)
- [ADR-006: no client result cache in 2.0](../adr/0006-no-client-result-cache-in-2.0.md)

## Current implementation anchors

- Routing header construction:
  [`client.ex:191`](../../lib/mcp/transport/streamable_http/client.ex#L191)
- Server header validation:
  [`plug.ex:258`](../../lib/mcp/transport/streamable_http/plug.ex#L258)
- Stateless dispatch contract:
  [`dispatch.ex:55`](../../lib/mcp/server/dispatch.ex#L55)
- Current capability models:
  [`client_capabilities.ex:13`](../../lib/mcp/protocol/capabilities/client_capabilities.ex#L13) and
  [`server_capabilities.ex:15`](../../lib/mcp/protocol/capabilities/server_capabilities.ex#L15)
- Current narrowed structured-content type:
  [`tools.ex:117`](../../lib/mcp/protocol/messages/tools.ex#L117)
