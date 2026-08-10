# ADR-004: Treat handler launch configuration as immutable

| | |
| --- | --- |
| **Status** | **Accepted** (2026-08-08) |
| **Date accepted** | 2026-08-08 |
| **Decision owner** | Product Owner |
| **Affects** | Handler behaviour, dispatch, HTTP and stdio server owners, S5 migration |
| **Related** | [ADR-002](0002-adopt-2026-07-28-stateless-core-migration.md), [2.0 contracts](../sdk-2.0/contracts.md#c5--stateless-dispatch) |

## Context

The current handler behaviour returns a replacement state from each callback,
and `MCP.Server.Dispatch` includes that state in its result. Neither the
Streamable HTTP Plug nor the stdio connection persists it. Describing that value
as threaded state is therefore false.

Persisting replacement state inside an HTTP request process would also conflict
with the 2026 stateless model: requests may reach different instances and must
not depend on hidden transport-local affinity. Mutable consumer data still has
legitimate uses, but OTP already provides explicit supervised ownership for it.

## Decision

`handler.init/1` returns immutable launch configuration. In the 2.0 API it is
named `handler_config`, passed to every callback, and never replaced by callback
output. Handler callbacks return only protocol/domain results; dispatch returns
`{:reply, response}` or `:noreply`.

A consumer that needs mutable state owns a separately supervised process, ETS
table, or other explicit store and places only its reference/name in
`handler_config`. Caller identity remains per-request `ToolContext` data and is
never stored in shared launch configuration.

## Consequences

- S5 changes the handler behaviour, dispatch result, and both transport owners
  together; no mixed contract ships.
- Existing handlers returning replacement state require a 2.0 migration.
- Stateful consumer operations become explicit OTP calls with independently
  testable supervision, concurrency, and recovery.
- The SDK cannot silently provide request affinity or session-like state.

## Alternatives considered

- **Persist callback state in each transport owner.** Rejected: HTTP request
  processes do not provide a coherent cross-request owner, and stdio/HTTP would
  have different semantics.
- **Add an SDK-global state process.** Rejected: hidden global ownership creates
  naming, isolation, and supervision problems for consumers running multiple
  endpoints.
- **Keep returning state but document that it is ignored.** Rejected: a public
  return value whose only observable behavior is data loss is not a contract.
