# Tri-Version Protocol and Secure Transports Design

**Status:** Approved design, pending implementation plan  
**Date:** 2026-08-10  
**Scope:** `mcp_elixir_sdk` 2.0 client/server protocol support, HTTP and stdio
transport security, conformance evidence, Phoenix integration, and release identity

## 1. Objective

Make the SDK safe to use as Phoenix's MCP gateway protocol engine and transport
implementation without maintaining Phoenix-specific forks.

The SDK will support three protocol revisions as first-class, version-isolated eras:

- `2026-07-28`, the preferred stateless revision;
- `2025-11-25`, a stateful legacy revision;
- `2025-06-18`, a stateful legacy revision.

The HTTP and stdio transports will expose configurable security policies with secure
defaults. The policies must be useful outside Phoenix, while their default guarantees
must satisfy the Phoenix gateway contract.

## 2. Non-goals

- Implementing the deprecated pre-Streamable-HTTP HTTP+SSE transport.
- Moving Phoenix authorization or downstream-origin validation into the SDK.
- Treating protocol revision support as a version-string alias.
- Publishing to Hex as part of implementation. Publishing remains an explicit operator
  action after all release evidence is complete.
- Guaranteeing portable descendant-process cleanup without platform-specific strategies
  and runtime tests.

## 3. Protocol architecture

### 3.1 Revision registry

One protocol registry will describe each supported revision. A revision entry identifies:

- its version string;
- its lifecycle module;
- its client and server adapter modules;
- its HTTP session/header behavior;
- its supported features and wire projections;
- its conformance profile.

Externally supplied version strings remain binaries. The implementation must not create
atoms from them.

### 3.2 Era isolation

`2026-07-28` remains stateless:

- no `initialize` or `notifications/initialized` exchange;
- no `Mcp-Session-Id`;
- request-local protocol, client identity, and capability metadata;
- `Mcp-Method` and, where required, `Mcp-Name` routing headers;
- optional `server/discover`;
- MRTR rather than held-open legacy server-to-client requests.

`2025-11-25` and `2025-06-18` use separate revision adapters behind a shared legacy
lifecycle behavior. Both perform initialization and capability negotiation, but each
adapter owns its exact wire projections and transport rules. Shared code is limited to
semantics proven identical by the pinned schemas and specifications.

The existing `MCP.Server.LegacyDispatch` must stop embedding one legacy version as a
global constant. Dispatch selects a revision adapter after validating initialization or
the established session. Likewise, `MCP.Client` delegates legacy messages and result
validation to the selected adapter.

### 3.3 Negotiation and fallback

Automatic negotiation attempts revisions in this order:

1. `2026-07-28`;
2. `2025-11-25`;
3. `2025-06-18`.

Fallback is bounded to one attempt per remaining configured revision. It is allowed only
after an explicit unsupported-version or incompatible-lifecycle result. It must not run
after authentication or authorization failure, TLS or DNS failure, URL-policy rejection,
malformed output, response overflow, timeout, or arbitrary upstream failure.

Once selected, a connection is pinned to one revision until reconnect or explicit reset.
Session identifiers and negotiated capabilities must never cross connections or revisions.
Explicit version configuration bypasses automatic probing.

## 4. Configurable HTTP security policy

### 4.1 Public policy type

`MCP.Transport.StreamableHTTP.SecurityPolicy` will be a validated struct accepted through
the transport's `:security_policy` option. Construction returns a controlled error for
invalid or internally inconsistent values.

The initial policy surface includes:

- allowed schemes, defaulting to HTTPS plus explicitly permitted loopback HTTP;
- whether non-loopback plaintext HTTP is permitted;
- trusted loopback/development destinations;
- redirect behavior, secure default `:reject`;
- connect, pool, receive/idle, and finite-operation deadlines;
- maximum wire-response bytes;
- maximum decoded-response bytes when content encoding is enabled;
- maximum SSE event and incomplete-event bytes;
- retry behavior, secure default disabled;
- compression behavior, initially disabled by the gateway-grade default;
- allowed static upstream headers and sensitive-header classification.

SDK applications may construct a different explicit policy, but they cannot silently
disable bounds by omitting the option.

### 4.2 URL validation

The endpoint is parsed and normalized once during transport initialization. It must be an
absolute `http` or `https` URI with a host and no userinfo or fragment. Production-grade
defaults reject non-loopback HTTP. Policy validation happens before any network request.

The SDK validates transport safety, not application authorization. The embedding gateway
remains responsible for ensuring that the configured endpoint is administrator-owned and
for any DNS/IP denylist or network-egress policy.

### 4.3 Request execution

POST, GET, and DELETE use one configured Req request template so URL, redirects, retry,
header, timeout, and body-limit behavior cannot drift between methods.

Finite responses are consumed incrementally. Bytes are counted before concatenation,
decompression, JSON decoding, or SSE parsing. The request is cancelled immediately when a
limit is crossed. When compression is enabled, both wire and decoded limits apply.

POST responses with `text/event-stream` are streamed rather than buffered. Long-lived GET
and subscription streams have bounded connect and idle phases, cancellation, maximum SSE
event size, and maximum incomplete-event size; they do not use a finite total lifetime by
default.

All 3xx responses are returned as policy errors under the default policy. A future explicit
redirect policy may revalidate every destination, but v2 does not need that complexity.

Downstream credentials are never accepted implicitly. Static upstream headers come only
from transport configuration and are checked against reserved MCP headers. Sensitive
headers are never included in errors or logs.

### 4.4 HTTP failure model

Policy failures use stable tagged errors such as invalid URL, insecure scheme, redirect
rejected, response too large, SSE event too large, connect timeout, idle timeout, and
request deadline exceeded. Network and HTTP errors retain structured causes without full
response bodies or secrets in logs.

## 5. Configurable stdio security policy

### 5.1 Public policy type

`MCP.Transport.Stdio.SecurityPolicy` will be a validated struct accepted through
`:security_policy`. It controls:

- maximum input frame/incomplete-line bytes;
- malformed-output action, secure default `:close`;
- environment behavior: inherit, clear-and-allowlist, or explicit replacement;
- stderr handling mode and diagnostic byte/rate limits;
- graceful shutdown deadline;
- forced termination deadline;
- process-tree strategy selected by platform/runtime capability.

### 5.2 Framing and validation

The transport checks the buffer limit before appending a new chunk. Complete frames are
processed iteratively with bounded work per mailbox turn so a stdout flood does not starve
the GenServer.

Each non-empty stdout frame must decode to a valid JSON-RPC request, notification, or
response. Malformed JSON, scalar/array JSON, and non-protocol objects fail the upstream
connection under the default policy. The owner receives a structured closure reason.

### 5.3 Environment and stderr

The default reusable SDK policy preserves current environment inheritance for backward
compatibility only when explicitly selected. The gateway-grade constructor clears the
environment and installs an allowlisted map plus required runtime variables.

Stderr is diagnostic data, never protocol data. The preferred implementation captures it
through a supervised, bounded channel that attributes diagnostics to the upstream and
redacts or truncates them before logging. If the selected platform cannot provide separate
bounded capture with the chosen process primitive, policy construction fails instead of
silently claiming the guarantee.

### 5.4 Process ownership and shutdown

The launcher owns an explicit process-management strategy rather than relying on
`Port.close/1` alone. Close performs:

1. stop accepting writes;
2. request graceful termination;
3. wait for confirmed direct-child exit up to the graceful deadline;
4. terminate the configured process group/tree;
5. wait up to the forced deadline;
6. report success or a structured cleanup failure.

Platform adapters may use different primitives, but must expose identical observable
semantics. Linux behavior must be tested on the actual Unraid runtime with a fixture that
spawns descendants.

## 6. Compatibility and migration

Existing transport startup calls remain source-compatible where they do not request unsafe
behavior. Both transports receive secure bounded defaults in the 2.0 line. Applications
that require different behavior must pass an explicit policy; there is no implicit
`unsafe: true` shortcut.

Policy modules provide named constructors:

- `default/0` for safe general SDK use;
- `gateway/0` for stricter server/gateway deployment;
- validated update functions for documented exceptions.

Phoenix uses `gateway/0` and supplies environment/header allowlists from administrator
configuration. Phoenix does not reach into private transport state.

## 7. Req compatibility

The SDK supports Req `>= 0.5.0 and < 0.8.0`, allowing Phoenix's Req 0.5 lock to resolve.
Integration compiles against Phoenix's real lock and exercises the lowest and highest
supported Req releases.

## 8. Verification and conformance

### 8.1 Protocol matrix

Every claimed revision receives:

- official server conformance where the pinned harness exposes an exact requirements profile;
- every applicable official client scenario;
- documented exclusions with an ownership/non-applicability rationale;
- HTTP and stdio tool-only interoperability tests;
- explicit-version and automatic-negotiation tests;
- unsupported-version, no-unsafe-fallback, and cross-session-isolation tests.

The machine-readable ledgers record the pinned harness version, exact commands, scenario
IDs, pass/fail/warning totals, exclusions, and artifact locations. Internal integration
coverage remains separately labeled and cannot substitute for an official denominator. The
pinned harness has no 2025-06-18 profile, so that absence and the SDK-owned June matrix are
recorded explicitly.

### 8.2 Security tests

HTTP tests cover invalid URLs, plaintext policy, every redirect status, secret-header
containment, oversized declared and chunked bodies, compressed expansion, slow responses,
connect/idle/total deadlines, oversized and unterminated SSE events, cancellation, and
POST/GET/DELETE policy parity.

Stdio tests cover partial frames at and above the limit, stdout floods, malformed and
non-JSON-RPC output, stderr floods and redaction, direct argv execution, environment
isolation, graceful exit, forced exit, descendant cleanup, and cleanup failure reporting.

### 8.3 Phoenix integration

A Phoenix integration branch pins the exact SDK coordinate, resolves dependencies from
Phoenix's actual lock, compiles with warnings as errors, runs the complete Phoenix suite,
and exercises one safe end-to-end gateway call over both HTTP and stdio. The Unraid runtime
test proves descendant cleanup rather than inferring it from local Linux behavior.

## 9. Release identity

After all gates pass:

- select the canonical repository and package provenance;
- bump to a new 2.0 prerelease or final version;
- align `mix.exs`, ExDoc `source_ref`, changelog, README installation coordinate, and tag
  naming;
- build and inspect the Hex archive;
- tag the exact verified commit without moving existing tags;
- verify a clean Phoenix dependency resolution selects the expected artifact and version.

Hex publication is intentionally outside the automatic implementation scope and requires
explicit operator authorization.

## 10. Delivery order

1. Introduce revision registry and `2025-06-18` version-isolated adapters.
2. Add policy types and shared error vocabulary.
3. Harden finite and streaming HTTP execution.
4. Harden stdio framing, diagnostics, and process ownership.
5. Complete three-version conformance and security matrices.
6. Verify Phoenix and actual-Unraid behavior.
7. Establish the new immutable release coordinate.

This order keeps protocol correctness independent from transport hardening while ensuring
no release coordinate is created before production evidence exists.

## 11. Primary references

- MCP 2025-06-18 transport specification:
  <https://modelcontextprotocol.io/specification/2025-06-18/basic/transports>
- MCP 2025-11-25 transport specification:
  <https://modelcontextprotocol.io/specification/2025-11-25/basic/transports>
- MCP 2026-07-28 release and stateless lifecycle:
  <https://blog.modelcontextprotocol.io/posts/2026-07-28/>
- Req 0.7 request, streaming, redirect, and retry options:
  <https://hexdocs.pm/req/Req.html>
- Phoenix gateway contract: `../phoenix/docs/mcp-gateway/SPEC.md`
