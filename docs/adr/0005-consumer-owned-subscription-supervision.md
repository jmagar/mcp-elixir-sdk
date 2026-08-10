# ADR-005: Use consumer-owned supervision for subscriptions

| | |
| --- | --- |
| **Status** | **Accepted** (2026-08-08) |
| **Date accepted** | 2026-08-08 |
| **Decision owner** | Product Owner |
| **Affects** | Subscription client API, server publication, supervision, back-pressure |
| **Related** | [ADR-004](0004-immutable-handler-launch-configuration.md), [runtime model](../sdk-2.0/runtime-models.md#m7--planned-subscription-supervisor) |

## Context

`subscriptions/listen` creates long-lived work with a different lifecycle from
ordinary request dispatch. HTTP subscriptions own response-scoped SSE streams;
stdio subscriptions share a transport and correlate by request ID. Client
consumers and server publishers also hold different state and failure duties.

Putting this work inside the current client or transport GenServer would let a
slow subscriber block unrelated requests. An SDK-global supervisor would make
multiple endpoints and consumer supervision policies interfere with each other.

## Decision

Applications enabling subscriptions supply a named `DynamicSupervisor` or pid.
Servers additionally supply a publication `Registry`. The SDK starts distinct
client-consumer and server-stream worker modules beneath that supervisor.

The client API returns an opaque handle consumed with bounded `next/2` and
closed with idempotent `close/1`. Both worker types default to 256 queued events,
with a configurable positive bound. Overflow terminates only that subscription,
records `:queue_overflow` locally, and never invents a successful MCP result.

HTTP `close/1` closes the request's SSE response stream; stdio sends
`notifications/cancelled`. Worker exit removes registry membership and cannot
terminate sibling subscriptions or ordinary requests.

## Consequences

- OTP ownership and restart policy remain visible in the host supervision tree.
- The SDK application keeps no global subscription singleton.
- Client and server lifecycle tests can isolate cancellation, overflow, owner
  loss, and sibling survival.
- Enabling subscriptions requires explicit supervisor configuration.

## Alternatives considered

- **Run subscriptions inside the transport GenServer.** Rejected: long-lived I/O
  and slow consumption would serialize unrelated work.
- **Start an unnamed SDK-global supervisor.** Rejected: it obscures ownership and
  creates collisions between endpoints and applications.
- **Expose a lazy Elixir `Stream`.** Rejected: it hides the worker lifecycle and
  makes deterministic close/error semantics harder to express.
- **Use unbounded mailboxes.** Rejected: a slow consumer can exhaust the VM.
