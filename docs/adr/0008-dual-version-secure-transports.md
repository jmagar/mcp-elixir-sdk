# ADR-008: Dual-version protocol adapters and secure transport policies

**Status:** Accepted (2026-08-10)

## Context

The gateway requires `2025-11-25` and `2026-07-28`. The SDK's protocol engine
already separated the stateless 2026 lifecycle from November 2025
compatibility, but the bundled HTTP and stdio clients did not provide
gateway-grade resource and subprocess controls.

## Decision

The SDK supports exactly those two revisions in newest-first order. The legacy
revision has its own adapter and exact initialize-version validation.
Fallback advances only for explicit version or lifecycle incompatibility;
authentication, TLS/network, malformed-response, overflow, and timeout failures
do not fall through to another revision.

HTTP and stdio expose validated policy structs. `gateway/0` is the hardened
preset. HTTP validates endpoints, disables redirects/retries/compression, and
bounds deadlines, finite bodies, and SSE events before decode. Stdio launches
an absolute executable plus argv without a shell, bounds protocol frames and
diagnostics, separates stderr, controls the environment, and confirms process
group plus Linux descendant cleanup.

## Consequences

- Gateway consumers can use the protocol engine and transports without copying
  policy logic, while ordinary SDK consumers may customize validated limits.
- Process-tree cleanup is complete for explicit close and protocol failure, but
  does not replace OS containment for a descendant that escapes its group before
  a spontaneous root exit; untrusted commands require a cgroup or sandbox.
- Version strings remain binaries and cannot create atoms.
- The November frozen client `sse-retry` scenario negotiates `2025-03-26`, which
  remains outside the declared support set and is a recorded
  release limitation rather than silently expanding compatibility.
