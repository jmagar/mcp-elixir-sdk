# ADR-002: Adopt MCP 2026-07-28; migrate the transport to the stateless core

> **Amendment:** sub-decisions 1 and 5 are superseded by
> [ADR-007](0007-dual-protocol-era-support.md). The stateless 2026 architecture
> remains the preferred path, but 2.0 also supports the 2025 protocol era.

| | |
| --- | --- |
| **Status** | **Accepted** (2026-07-20) · _amended 2026-07-23 — factual correction, decision unchanged_ |
| **Date drafted** | 2026-07-20 |
| **Date accepted** | 2026-07-20 |
| **Decision owner** | Product Owner (accepted) |
| **Drafted by** | Active-sprint PM |
| **Consumer in the loop** | EMFA — cuts over to 2.0.0 as soon as it's available; remains the dogfooding consumer |
| **Supersedes** | [ADR-001](0001-target-2025-11-25-defer-2026-07-28.md) — the **deferral** only |
| **Affects** | Transport (Streamable HTTP), protocol layer, the `handler_opts` seam, conformance target, EMFA |

## Context

ADR-001 deferred MCP 2026-07-28 because the target was a release candidate that could still change and
no verified baseline existed. Both conditions have now changed:

- **The RC is locked.** The 2026-07-28 release candidate is locked as of 2026-05-21; the final
  specification publishes **2026-07-28**. The ten-week window to that date is explicitly for SDK
  maintainers to validate against real workloads, and Tier 1 SDKs are expected to ship support within
  it. Building against the locked RC is the intended path, not a redo risk.
- **A consumer requirement now drives adoption.** While dogfooding 1.1.0, EMFA hit a problem with
  `session_id` and is moving to a session-less model — which is exactly what 2026-07-28 codifies (the
  `Mcp-Session-Id` header and protocol-level session are removed, so any request can land on any
  instance behind a round-robin balancer). Consumer-driven, not speculative.
- **A verified baseline now exists.** 1.1.0 shipped against 2025-11-25 and is in production use at
  EMFA; we migrate from a known-good state.
- **The revision is well-instrumented for adopters.** The stateless core is delivered by **six SEPs
  working together**; **authorization hardening accounts for a further six**; the release additionally
  carries the extensions framework, the feature-lifecycle/deprecation policy, routing headers, caching
  hints, trace context, and error-code changes. **No official SEP total is published** — the
  authoritative inventory is the **draft changelog ("Key Changes")** plus the
  [SEP index](https://modelcontextprotocol.io/seps). Four Tier 1 reference SDKs (Python v2,
  TypeScript v2, Go, C#) are already in public beta against the RC, and the conformance suite
  (`@modelcontextprotocol/conformance` — the same harness this project already runs) covers the
  revision, since a Standards Track SEP cannot reach Final until a matching conformance scenario lands
  (SEP-2484). So the migration has a SEP inventory, reference implementations, and an automated
  conformance target to build against — not just prose.

Key protocol changes (verify against the changelog + reference SDKs at the spec-first pass — anchor
SEPs noted):

- `initialize`/`initialized` handshake **removed** (SEP-2575); protocol version, client info,
  capabilities move to `_meta` per request, with a `server/discover` method.
- Server-side session state / `Mcp-Session-Id` **removed** (SEP-2567); the per-session `MCP.Server`
  GenServer + session lookup lose their protocol basis. Cross-call state becomes explicit
  **state handles**.
- **Multi Round-Trip Requests** (SEP-2322 / `InputRequiredResult`) replace held-open SSE for
  server→client requests; server-initiated requests may only be issued while actively processing a
  client request (SEP-2260).
- **Extensions framework** (SEP-2133) — reverse-DNS IDs, negotiated via an extensions map, versioned
  independently; Roots/Sampling/Logging deprecated in its favour.
- **Feature lifecycle / deprecation policy** (SEP-2577 + SEP-2596) — Active → Deprecated → Removed,
  minimum 12 months between deprecation and earliest removal. **No feature is removed in 2026-07-28.**
- **Routing headers** `Mcp-Method` / `Mcp-Name` (SEP-2243), enabling gateway routing without body
  inspection; caching hints (`ttlMs` / `cacheScope`) on list/read results.
- **W3C Trace Context** propagation in `_meta` (SEP-414) — `traceparent`, `tracestate`, `baggage` key
  names fixed.
- **Error codes:** missing-resource `-32002` → standard `-32602` Invalid Params (SEP-2164); further
  renumbering to verify at the spec-first pass (e.g. HeaderMismatch `-32020`,
  MissingRequiredClientCapability `-32021`, UnsupportedProtocolVersion `-32022`).
- Tool `inputSchema`/`outputSchema` → full JSON Schema 2020-12.

## Decision

**Adopt MCP 2026-07-28 as the SDK's target revision and migrate the Streamable-HTTP transport to the
stateless protocol core, now** — building against the locked RC, tracking to the 2026-07-28 final. The
vehicle is a breaking **2.0.0** release. This supersedes ADR-001's _deferral_; it does not disturb the
shipped 1.1.0 (which remains on 2025-11-25).

## Sub-decisions (resolved by PO, 2026-07-20)

1. ~~**No parallel support — package-level cutover.** `main` moves to 2.0.0/stateless. Consumers who
   want the old spec stay on Hex `{:mcp_elixir_sdk, "~> 1.1"}` (immutable on Hex, so it remains
   available at zero cost). See sub-decision 5 for the mechanism choice.~~ **Superseded by ADR-007.**
2. **The `~> 1.1` line is frozen except for security fixes.** No feature backports. A security issue in
   the 1.1.x code EMFA runs in production may warrant a 1.1.x patch; nothing else.
3. **EMFA cuts over to 2.0.0 as soon as it's available.** EMFA remains the dogfooding consumer for the
   migration — its session-less requirement is the acceptance signal, preserving the loop that
   validated the seam. (Confirmed: EMFA needs **no interim relief** on 1.1.x before then.)
4. **Full conformance to the 2026-07-28 revision in its entirety, not a subset.** "Do everything" is
   simpler than cherry-picking interdependent SEPs. Conformance target = `@modelcontextprotocol/conformance`;
   self-certify against it rather than shipping "RC-complete, pending suite."
5. ~~**Package-level cutover, NOT in-SDK dual-era negotiation.** The reference SDKs (e.g. C# 2.0.0-preview)
   keep _both_ protocol eras alive in one package — clients negotiate down to the legacy handshake,
   servers accept both. We deliberately do **not** do that. For a small SDK with a single known
   consumer moving in lockstep, in-SDK dual-era is complexity EMFA doesn't need; package immutability on
   Hex already provides the fallback. This is a stated, deliberate divergence from the reference-SDK
   approach.~~ **Superseded by ADR-007.**
6. **Identity-threading redesign is owned by the spec-first design pass** (see Consequences).
7. **Version: 2.0.0** (breaking major). EMFA coordinates its constraint at cutover.

## Consequences

- **Multi-sprint transport rewrite, not an increment.** The per-session GenServer model, handshake, and
  session routing are all reworked. The breadth of the revision — a stateless core plus an auth
  overhaul, extensions, routing, caching and error-code changes — confirms the size.
- **The `handler_opts` seam needs a new identity-binding design** — the migration's hardest problem.
  Today it binds identity **once at the `initialize` session** — the exact point 2026-07-28 removes. The
  stateless replacement for cross-call state is a model-passed **state handle**, but **identity must not
  be model-passed** (the seam exists to keep identity out of model control). So a fresh mechanism is
  required to bind pipeline-established identity per request without a session. **Settled spec-first
  before any implementation.** See
  [Identity-threading design input](https://vidhya-trading.atlassian.net/wiki/spaces/ElixirMCPS/pages/234422273).
- **1.1.0 / 2025-11-25 stays valid and available** on Hex; deprecations in the new spec are
  annotation-only for ≥12 months. No parallel maintenance burden given the cutover.
- **Conformance target moves** to the 2026-07-28 suite; the SDK-tier claim is gated on the scenarios,
  which land as SEPs finalise. Risk that independent verification of a given SEP lags its
  implementation is **lower than first thought** — the harness and four reference SDKs already exist to
  validate against.
- **CAND-A (client OAuth 2.1) overlaps** the 2026-07-28 authorization hardening (itself six SEPs) —
  plan together.

## Open items for migration planning (not blocking this ADR)

- **Identity-threading design** under stateless — the spec-first pass owns it.
- **2.0.0 branch/version strategy** and the mechanics of freezing the `1.1.x` line (security-only).
- **Reference-SDK leverage:** decide which reference migration to lean on hardest (C# maps
  SEPs→behaviour most explicitly; Python v2 / TypeScript v2 are the leads).

## Alternatives considered

- **Stay on 2025-11-25 / keep deferring.** Rejected: the consumer needs session-less operation now; the
  SDK would fall behind a spec designed to be the stable base going forward.
- **Wait for the 2026-07-28 final before any work.** Rejected: the RC is locked and the window is _for_
  implementation; we'd lose ~10 weeks for no risk reduction. (We read the draft spec + changelog +
  reference SDKs, not the blog, as the authoritative surface.)
- **Adopt only the non-breaking pieces** (error codes, JSON Schema 2020-12). Rejected: doesn't solve
  EMFA's session-less need, the whole driver.
- **In-SDK dual-era support** (the reference-SDK approach). Rejected per sub-decision 5 — unnecessary
  complexity for one lockstep consumer with a package-level fallback.

## Next steps (on acceptance — now in effect)

1. Open **Sprint 3** as the spec-first stateless-core migration. First ticket: read the draft changelog
   ("Key Changes") + the SEP index + reference-SDK migrations (esp. C#), and produce (a) an
   implemented-vs-2026-07-28 gap analysis, (b) the identity-threading redesign, (c) confirmation of
   conformance-suite coverage for the revision.
2. EMFA rides it as the dogfooding consumer; cuts over to 2.0.0 on availability.
3. CC lands ADR-001 + ADR-002 into `docs/adr/` as the canonical source-of-truth copies (this
   Confluence page is the ratified draft).

---

## Amendment log

**2026-07-23 — factual correction (decision unchanged).** The originally-ratified text stated the
release "comprises 22 SEPs" in four places. CC's landing-verification pass could not substantiate that
total, and a PM re-check confirmed it: no official SEP total is published. Sources frame the
**stateless core as six SEPs** and **authorization hardening as a further six**, with additional SEPs
for extensions, lifecycle, routing, caching, trace context and error codes. The unsupported count was
removed and replaced with the accurate framing plus a pointer to the authoritative inventory (draft
changelog + SEP index); sub-decision 4 was reworded to "the revision in its entirety, not a subset" so
it no longer depends on a number. Newly-confirmed SEP anchors (2164, 2243, 2260, 2577/2596, 414) were
folded into the key-changes list. **No sub-decision, scope, or version choice changed**;
re-ratification was not required. Raised by CC, corrected by PM, applied with PO approval.
