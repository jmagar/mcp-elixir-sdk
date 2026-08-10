# ADR-006: Do not cache MCP results in the 2.0 client

| | |
| --- | --- |
| **Status** | **Accepted** (2026-08-08) |
| **Date accepted** | 2026-08-08 |
| **Decision owner** | Product Owner |
| **Affects** | Client behavior, cacheable result types, identity isolation, conformance |
| **Related** | [ADR-003](0003-2.0.0-conformance-scope.md), [cache contract](../sdk-2.0/contracts.md#c10--cacheable-results) |

## Context

The 2026 schema exposes `ttlMs` and `cacheScope` on cacheable results, but those
hints do not require an SDK client cache. A correct cache would need endpoint
identity, normalized params, protocol version, caller partitioning for private
results, invalidation, bounds, and behavior for unknown scopes.

Implementing that policy inside the 2.0 migration would add security-sensitive
state while the client lifecycle and subscription invalidation surfaces are
still changing. Silently caching only some results would be worse than a clear
no-cache contract.

## Decision

The 2.0 client performs no MCP result caching. It preserves and exposes
`resultType`, `ttlMs`, and `cacheScope`, but every API invocation reaches the
transport. Repeated identical requests are not satisfied from SDK memory.

Adding result caching later requires a separate ADR and release contract that
defines keys, identity partitioning, invalidation, limits, observability, and
unknown-scope behavior.

## Consequences

- No stale or cross-principal result can be introduced by an SDK cache.
- Cache hints remain available to host applications that deliberately implement
  their own policy.
- Repeated calls may use more network/server capacity than a conforming cache.
- S5 tests prove repeated public and private calls both reach the server.

## Alternatives considered

- **Implement a complete bounded cache in 2.0.** Rejected: it expands the
  critical path with identity-sensitive state unrelated to core interoperability.
- **Cache only public results.** Rejected: partial policy is surprising and still
  requires invalidation and endpoint-key decisions.
- **Discard cache hints.** Rejected: the wire values are protocol data and must
  remain visible to hosts and round-trip correctly.
