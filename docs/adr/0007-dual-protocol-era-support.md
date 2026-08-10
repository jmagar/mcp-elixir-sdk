# ADR-007: Support both 2025-11-25 and 2026-07-28 in the 2.0 SDK

**Status:** Accepted — product-owner correction, 2026-08-09
**Supersedes:** ADR-002 sub-decisions 1 and 5, and ADR-003 decision item 5 only

## Context

The original SDK requirement was full wire support for both the stateful
`2025-11-25` protocol and the stateless `2026-07-28` protocol. ADR-002 and
ADR-003 later introduced a package-level hard cutover without reconciling that
decision with the hard compatibility requirement. The resulting 2.0
implementation rejected old clients and could not connect to old servers.

The two revisions differ in lifecycle and transport semantics, not merely a
version constant:

- `2025-11-25` uses `initialize`, `notifications/initialized`, negotiated
  capabilities, HTTP session IDs, session DELETE, resource subscriptions, and
  independent server-to-client sampling/roots/elicitation requests.
- `2026-07-28` uses `server/discover`, required per-request metadata, no
  protocol session, unified subscriptions, MRTR, and stateless HTTP routing.

## Decision

The 2.0 SDK supports both revisions in one package and prefers
`2026-07-28`. Protocol-specific lifecycle and transport behavior remain
isolated behind versioned runtime paths.

1. `MCP.Protocol.supported_versions/0` returns newest first:
   `2026-07-28`, then `2025-11-25`.
2. A default client probes with `server/discover`. A server response that
   advertises only `2025-11-25`, or rejects discovery as method-not-found,
   causes one bounded fallback to the legacy initialize handshake.
3. An explicitly configured `2025-11-25` client starts with `initialize` and
   never emits stateless per-request metadata.
4. `MCP.Server.Connection` selects one protocol mode per connection. An
   initialize request selects the legacy state machine; a stateless request
   selects the 2026 dispatcher. Modes cannot be mixed afterward.
5. The Streamable HTTP Plug serves both modes at one endpoint. Legacy sessions
   bind identity at initialize, mint `Mcp-Session-Id`, re-authenticate and
   compare the bound principal on every POST/GET/DELETE, expose an SSE channel
   for server requests, and terminate via DELETE. The 2026 path remains
   independently serviceable without session affinity.
6. Legacy responses omit 2026-only `resultType`, `ttlMs`, and `cacheScope`
   members. Stateless responses retain them.
7. Legacy resource subscriptions, logging controls, list-change/resource
   notifications, progress, and sampling/roots/elicitation requests remain
   available only on the legacy path. Unified subscriptions and MRTR remain
   available only on the stateless path.
8. Authorization identity is never taken from wire arguments or `_meta` in
   either mode. The legacy HTTP identity factory establishes the binding at
   initialize and is re-evaluated on every session request; the stateless
   factory runs per request.

## Consequences

- Older clients can use a current server, and current clients can negotiate
  down to older servers without pinning the 1.x package.
- Legacy HTTP requires bounded server-side session state and therefore does
  not inherit the no-affinity property of the 2026 path.
- The SDK supervisor owns the default legacy session manager. Endpoint and
  per-principal quotas plus idle/absolute expiry make abandoned state finite.
- Conformance is measured separately for each revision and each client/server
  transport role. A green 2026 matrix does not imply 2025 conformance, or vice
  versa.
- New core behavior must declare which protocol eras it affects and add
  isolation tests when behavior differs.

## Rejected alternatives

- **Keep 1.1.x as the compatibility mechanism.** Rejected because it violates
  the one-package hard requirement and prevents applications from serving old
  and new peers simultaneously.
- **Translate every legacy message into the stateless protocol.** Rejected
  because sessions and independent server requests have no faithful stateless
  equivalent.
- **Scatter version conditionals through one dispatcher.** Rejected because it
  makes lifecycle and security invariants difficult to review and test.

## Verification

The acceptance matrix includes explicit and negotiated clients, in-process /
stdio connections, real Streamable HTTP sessions, session-header reuse and
DELETE, protocol-shape isolation, legacy resource/logging callbacks,
notifications, and server-initiated sampling over the legacy HTTP SSE channel.
