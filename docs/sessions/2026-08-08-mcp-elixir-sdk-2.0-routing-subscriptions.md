---
date: 2026-08-08 22:53:04 EDT
repo: git@github.com:jmagar/mcp-elixir-sdk.git
branch: codex/mcp-routing-headers
head: 332235c28423246299b8f837330e35247b43b5d1
working directory: /home/jmagar/workspace/mcp-elixir-sdk
worktree: /home/jmagar/workspace/mcp-elixir-sdk
---

# MCP Elixir SDK 2.0 routing and subscriptions

## User Request

Review the existing Elixir MCP SDK, fork it, establish substantive 2.0 specifications and contracts, implement the work in test-first slices, publish the repository, and continue through adversarial review.

## Session Overview

The session forked and published the SDK, implemented the 2026-07-28 standard and custom routing-header slice, added the substantive 2.0 documentation package and three durable ADRs, and built the first three subscription sub-slices: codecs, client ownership/queueing, and server publication/queueing. The checkpoint was pushed, all ten prior correctness findings were fixed test-first, and a fresh eight-role Lavra closure review produced nine additional unique issues that were also resolved.

## Sequence of Events

1. Reviewed the upstream SDK and confirmed that it already uses OTP but lacks the intended 2.0 stateless-core work.
2. Forked the SDK into `/home/jmagar/workspace/mcp-elixir-sdk`, created `codex/mcp-routing-headers`, and established a test-first slice plan.
3. Implemented routing headers, schema-driven `Mcp-Param-*` handling, bounded schema descriptors, identity-aware server validation, and one-shot refresh behavior.
4. Added normative specifications, contracts, types, runtime models, the meta-plan, and ADRs for immutable handler configuration, consumer-owned subscription supervision, and no result cache.
5. Implemented subscription codecs and supervised client/server workers with bounded queues and publication filtering.
6. Ran an eight-role Lavra review and reproduced its ten unique findings with failing tests.
7. Pushed the S2a-S2c checkpoint as `256f22c`, then fixed all ten findings.
8. Ran a fresh eight-role closure review, reconciled nine unique actionable findings, and addressed every one test-first.
9. Verified the complete tree with 295 serialized tests, formatting, strict Credo, Dialyzer, and patch hygiene.

## Key Findings

- The baseline is `2b34b32`; routing/docs were committed as `332235c` and pushed to `origin/codex/mcp-routing-headers`.
- The S2a-S2c checkpoint is pushed as `256f22c`; its closure remediation is green at 295 tests with strict Credo, Dialyzer, formatting, and diff checks clean.
- Review reproduced subscription event loss after a timed-out `next/2` in both worker implementations.
- Review found remotely triggerable crashes from malformed nested routing arguments and malformed `tools/list` entries.
- Closure review additionally drove structural wire validation, bounded schema-refresh pagination, strict catalog schemas, publication validation, linear routing descriptor compilation, and alignment of the public protocol version.

## Technical Decisions

- The 2.0 target is the stateless MCP `2026-07-28` core, with per-request metadata and no initialization session.
- Handler launch configuration is immutable; mutable consumer state belongs in explicit OTP owners.
- Subscription supervision and server publication registries are consumer-owned, with no SDK-global singleton.
- Subscription queues are bounded at 256 by default and overflow terminates only the affected subscription.
- The SDK preserves cache hints but does not cache MCP results in 2.0.

## Files Changed

| Status | Path | Previous path | Purpose | Evidence |
| --- | --- | --- | --- | --- |
| modified | `README.md` | — | Mark the 2.0 migration and link normative docs | `git diff 2b34b32` |
| modified | `conformance/client_adapter.exs` | — | Add routing-header scenario coverage | `332235c` |
| created | `docs/adr/0004-immutable-handler-launch-configuration.md` | — | Preserve handler configuration decision | `332235c` |
| created | `docs/adr/0005-consumer-owned-subscription-supervision.md` | — | Preserve subscription ownership decision | `332235c` |
| created | `docs/adr/0006-no-client-result-cache-in-2.0.md` | — | Preserve client cache decision | `332235c` |
| modified | `docs/adr/README.md` | — | Register ADRs 004-006 | `332235c` |
| created | `docs/sdk-2.0/contracts.md` | — | Define boundary and failure contracts | `332235c` |
| created | `docs/sdk-2.0/meta-plan.md` | — | Track slices, evidence, risks, and progress | current worktree |
| created | `docs/sdk-2.0/runtime-models.md` | — | Define OTP ownership and lifecycle models | `332235c` |
| created | `docs/sdk-2.0/specifications.md` | — | Define normative 2.0 behavior | `332235c` |
| created | `docs/sdk-2.0/types.md` | — | Define wire and public types | `332235c` |
| created | `docs/sessions/2026-08-08-mcp-elixir-sdk-2.0-routing-subscriptions.md` | — | Preserve this session checkpoint | current worktree |
| modified | `lib/mcp/client.ex` | — | Add routing schema index and refresh behavior | `332235c` |
| created | `lib/mcp/client/subscription_handle.ex` | — | Add opaque subscription consumer handle | current worktree |
| created | `lib/mcp/client/subscription_worker.ex` | — | Add bounded supervised client queue | current worktree |
| modified | `lib/mcp/protocol/methods.ex` | — | Add subscription method constants | current worktree |
| created | `lib/mcp/protocol/messages/subscriptions/acknowledged_params.ex` | — | Add acknowledgment codec | current worktree |
| created | `lib/mcp/protocol/messages/subscriptions/listen_params.ex` | — | Add listen request codec | current worktree |
| created | `lib/mcp/protocol/messages/subscriptions/listen_result.ex` | — | Add graceful result codec | current worktree |
| created | `lib/mcp/protocol/tool_routing.ex` | — | Validate annotations and routing arguments | `332235c` |
| created | `lib/mcp/protocol/types/subscription_filter.ex` | — | Add strict subscription filter type | current worktree |
| modified | `lib/mcp/protocol/types/tool.ex` | — | Enforce object-root tool input schemas | `332235c` |
| created | `lib/mcp/server/subscription_publisher.ex` | — | Filter and dispatch subscription notifications | current worktree |
| created | `lib/mcp/server/subscription_registry.ex` | — | Resolve publication registry references | current worktree |
| created | `lib/mcp/server/subscription_worker.ex` | — | Add bounded server subscription worker | current worktree |
| modified | `lib/mcp/transport.ex` | — | Add optional transport send options | `332235c` |
| modified | `lib/mcp/transport/streamable_http/client.ex` | — | Emit standard and custom routing headers | `332235c` |
| modified | `lib/mcp/transport/streamable_http/plug.ex` | — | Enforce routing headers and identity-aware schemas | `332235c` |
| modified | `mix.exs` | — | Update fork metadata and HexDocs extras | `332235c` |
| modified | `test/mcp/client_test.exs` | — | Cover schema index and refresh behavior | `332235c` |
| created | `test/mcp/client/subscription_worker_test.exs` | — | Cover client worker lifecycle and queues | current worktree |
| modified | `test/mcp/protocol/methods_test.exs` | — | Cover subscription method constants | current worktree |
| created | `test/mcp/protocol/messages/subscriptions_test.exs` | — | Cover subscription message codecs | current worktree |
| created | `test/mcp/protocol/types/subscription_filter_test.exs` | — | Cover strict filter codec | current worktree |
| modified | `test/mcp/protocol/types/tool_test.exs` | — | Cover input schema object roots | `332235c` |
| created | `test/mcp/server/subscription_worker_test.exs` | — | Cover publication, filtering, overflow, and cleanup | current worktree |
| modified | `test/mcp/transport/streamable_http_ac_test.exs` | — | Align HTTP acceptance tests | `332235c` |
| created | `test/mcp/transport/streamable_http_client_test.exs` | — | Cover client routing headers | `332235c` |
| modified | `test/mcp/transport/streamable_http_stateless_test.exs` | — | Cover server routing enforcement | `332235c` |
| modified | `test/support/mock_transport.ex` | — | Capture transport options | `332235c` |
| created | `test/support/request_capture_plug.ex` | — | Capture outbound HTTP requests | `332235c` |

## Beads Activity

No bead activity was observed. `bd where` reports that this repository has no active Beads workspace; initialization was not inferred.

## Repository Maintenance

- Plans: no `docs/plans` files exist, so nothing was moved.
- Beads: unavailable because no Beads database exists; no tracker state was changed.
- Worktrees and branches: the repository has one worktree. `main` is protected from cleanup and the active feature branch is unmerged, so no branch or worktree was removed.
- Stale docs: the 2.0 documentation package and meta-plan were updated during the session; the README's full 2.0 cutover remains explicitly assigned to S6.
- Changelog: it has no commit-summary table anchor, so quick-push left it unchanged rather than guessing a new format.

## Tools and Skills Used

- Shell and Git: repository inspection, diffs, branch creation, commits, pushes, and verification.
- Elixir tooling: `mix test`, focused ExUnit runs, formatter, Credo, and Dialyzer through pinned mise runtimes.
- GitHub CLI: fork/remote and hosted repository inspection.
- Elixir skill: OTP, GenServer, supervision, and ExUnit guidance.
- Lavra Review: eight review roles distributed across three subagents; findings were reconciled and reproduced locally.
- Quick Push and Save to Markdown: checkpoint documentation and publication workflow.

## Commands Executed

| Command | Result |
| --- | --- |
| `mise x erlang@27.2.3 elixir@1.18.4-otp-27 -- mix test --max-cases 1 --seed 0` | 295 tests, 0 failures |
| `mise x erlang@27.2.3 elixir@1.18.4-otp-27 -- mix credo --strict` | No issues |
| `mise x erlang@27.2.3 elixir@1.18.4-otp-27 -- mix dialyzer` | 0 errors |
| `mix format --check-formatted` | Passed under pinned runtime |
| `git diff --check` | Passed |
| `gh pr list --head codex/mcp-routing-headers` | No PR exists |

## Errors Encountered

- The host default Elixir toolchain was unsuitable for this branch; pinned Erlang 27.2.3 and Elixir 1.18.4 were used through mise.
- The project emits broad pre-existing incremental Jason protocol redefinition warnings during compilation; tests still pass.
- Beads commands fail because this checkout has no Beads database.

## Behavior Changes (Before/After)

| Area | Before | After |
| --- | --- | --- |
| HTTP routing | Optional/incomplete routing-header checks | Required standard headers plus schema-driven custom headers |
| Handler identity | Per-request seam without selected-schema validation | Identity-aware schema resolution before dispatch |
| Documentation | Scattered historical planning | Normative specifications, contracts, types, models, ADRs, and evidence ledger |
| Subscriptions | No 2026 unified subscription primitives | Codecs and separately supervised client/server queue workers |

## Verification Evidence

| Command | Expected | Actual | Status |
| --- | --- | --- | --- |
| Full ExUnit suite | All tests pass | 295 tests, 0 failures | Pass |
| Strict Credo | No findings | No issues | Pass |
| Dialyzer | No errors | 0 errors | Pass |
| Formatter | No changes required | Passed | Pass |
| Diff check | No whitespace errors | Passed | Pass |

## Risks and Rollback

The branch remains development-only and is not merged into `main`. Rollback is non-destructive: revert the feature commits or continue from baseline tag `2.0.0-dev.1` (`2b34b32`). The two Lavra waves are closed; S2 transport wiring and the later release slices remain incomplete.

## Decisions Not Taken

- No SDK-global subscription supervisor was added because ownership belongs to consumers.
- No MCP result cache was added because a correct identity-partitioned policy is outside the 2.0 migration.
- No Beads database was initialized because repository tracker adoption was not requested.
- No version bump was made by quick-push because its supported primary manifest set is absent.

## References

- MCP `2026-07-28` schema pinned at commit `5f5440bb26a62e2cf3440b92da5a667efa03b267`.
- `docs/sdk-2.0/meta-plan.md` for current slice evidence and remaining gates.
- `docs/adr/0004-immutable-handler-launch-configuration.md` through `0006-no-client-result-cache-in-2.0.md`.

## Open Questions

- Whether this fork should adopt Beads before future Lavra review waves.
- Whether the current feature branch should become a pull request after review closure.

## Next Steps

1. Commit and push the completed adversarial remediation.
2. Continue S2 transport wiring for `listen_subscriptions` over stdio and HTTP.
3. Add official client/server subscription scenarios before marking S2 verified.

## 2026-08-09 dual-era compatibility correction

### User request and outcome

The user identified `2025-11-25` backward compatibility as a hard requirement
for SDK 2.0. The implementation now supports both `2026-07-28` and
`2025-11-25` on client and server, with one bounded client downgrade, strict
mode isolation, and version-specific wire dispatch.

### Implementation

- Added `MCP.Server.LegacyDispatch` and the stateful Streamable HTTP
  `LegacySession` transport, including initialize/initialized, session IDs,
  SSE GET, POST correlation, DELETE, independent server requests, and bounded
  event queues.
- Restored legacy client APIs and callbacks for ping, resource subscriptions,
  roots, sampling, elicitation, and notifications while preserving the 2026
  stateless core.
- Added handler callbacks for subscription ownership and logging level, stale
  session cleanup, continuation-worker failure handling, and explicit legacy
  identity binding.
- Added ADR-007 plus updated specifications, contracts, types, runtime models,
  architecture, tooling, changelog, README, and the machine-readable 2025
  conformance ledger.

### Verification evidence

| Command | Actual | Status |
| --- | --- | --- |
| `mix test --seed 0` | 379 tests, 0 failures | Pass |
| `mix compile --warnings-as-errors` | Compilation succeeded | Pass |
| `mix credo --strict` | 1377 functions/modules, no issues | Pass |
| `mix dialyzer` | 0 errors | Pass |
| `mix docs` and `mix hex.build` | Documentation and package generated | Pass |
| Official server requirements `2025-11-25` | 81 passed, 0 failed | Pass |
| Official `server-stateless` scenario `2026-07-28` | 30 passed, 0 failed | Pass |

### Repository maintenance

- No `docs/plans` directory or Beads database was present, so no plan or
  tracker state was changed.
- The repository has one worktree on `codex/mcp-routing-headers`; no worktree or
  branch cleanup was safe or necessary.
- Current documentation contradicted the restored compatibility requirement in
  several places; those stale claims were superseded or corrected.
- The quick-push manifest detector found no Cargo, npm, or Python primary
  manifest, so it made no automatic version bump. The Mix package remains
  `2.0.0-dev.1`.

### Remaining work

The dual-era implementation is locally verified but still requires the
requested post-push Lavra review. Any actionable review findings must be fixed,
retested, committed, and pushed before this branch is considered ready for a
merge decision.

## 2026-08-09 post-push Lavra remediation

The requested touched-file review completed across protocol, security,
runtime/OTP, performance, data-integrity, simplicity, history, and
agent-native boundaries. All actionable findings were converted into failing
regressions before remediation.

Closed work includes compile-safe Phoenix Plug options; supervised and
principal-bound legacy sessions with endpoint/per-principal quotas,
idle/absolute expiry, endpoint-owner cleanup, and bounded waiters; configurable
canonical Host/Origin policy; atomic/idempotent client negotiation and rollback;
HTTP 400 downgrade plus one-shot 404 recovery; incremental/restarting SSE;
negotiated server-request capability checks; bounded callback and MRTR work;
mode-isolated notifications; malformed legacy parameter handling; and truthful
release evidence. A full sequential run also surfaced and fixed a cleanup race
where a dead transport could crash the client while a subscription worker was
terminating.

Final evidence after remediation:

| Command | Actual | Status |
| --- | --- | --- |
| `mix test --seed 0 --max-cases 1` | 414 tests, 0 failures | Pass |
| Focused adversarial regression matrix | 45 tests, 0 failures | Pass |
| `mix compile --warnings-as-errors` | Compilation succeeded | Pass |
| `mix credo --strict` | No issues | Pass |
| `mix dialyzer` | 0 errors | Pass |
| `mix docs` and `mix hex.build` | Documentation and package generated | Pass |
| Official server requirements `2025-11-25` | 81 passed, 0 failed | Pass |
| Official `server-stateless` scenario `2026-07-28` | 30 passed, 0 failed | Pass |

The official 2025 client evidence is intentionally reported as one initialize
scenario plus the local cross-transport matrix; it is not presented as a full
official client denominator.

## 2026-08-09 final branch publication

Before creating the upstream pull request, the final dirty-set audit found four
coherent follow-up changes: a canonical `mix precommit` alias, matching README
and development-tooling guidance, and a deterministic legacy callback-response
assertion that waits for the expected outbound message instead of sampling the
transport's last message. The first full precommit run then reproduced an HTTP
subscription test race: its `2_000` timeout was implemented as a busy-loop
attempt count and could expire in roughly 20 milliseconds. The helper now uses
a monotonic deadline and condition wait; the focused overflow case passed 50
consecutive runs afterward. These changes are part of the same compatibility
and hardening scope and were included in the final branch commit.

The canonical precommit alias now runs formatting, warnings-as-errors
compilation, the seed-zero test suite, Credo, Dialyzer, documentation and Hex
package builds, Hex dependency auditing, unused-dependency detection, Git
whitespace validation, and both conformance-ledger JSON checks. Merging the two
new upstream commits advanced the package to `2.0.0-dev.2`; the README,
changelog, and conformance adapter identities were synchronized to that version.
The resolved merge passed the combined 69-test protocol/collector matrix and
the full `mix precommit` gate with 428 tests and zero failures.
