---
date: 2026-08-10 02:16:19 EDT
repo: git@github.com:jmagar/mcp-elixir-sdk.git
branch: main
head: bf2d4ef8124de342dc7de5a1d3607cd9d2fd2ffa
working directory: /home/jmagar/workspace/mcp-elixir-sdk
worktree: /home/jmagar/workspace/mcp-elixir-sdk
pr: "#1 feat: complete MCP 2.0 dual-protocol SDK (https://github.com/jmagar/mcp-elixir-sdk/pull/1)"
beads: mcp-elixir-sdk-7yz, mcp-elixir-sdk-7yz.1, mcp-elixir-sdk-7yz.2, mcp-elixir-sdk-7yz.3, mcp-elixir-sdk-7yz.4, mcp-elixir-sdk-7yz.5, mcp-elixir-sdk-7yz.6, mcp-elixir-sdk-7yz.7, mcp-elixir-sdk-7yz.8, mcp-elixir-sdk-7yz.9
---

# MCP Elixir SDK dual-protocol implementation and closeout

## User Request

Review and extend the Elixir MCP SDK as a production OTP-native SDK, implement every planned slice with exhaustive tests, restore the hard requirement for full `2025-11-25` compatibility alongside `2026-07-28`, adversarially review all touched work, land it on the user's fork, and merge it into `main`.

## Session Overview

The session turned the fork into a dual-era MCP client/server SDK with OTP supervision, stdio and Streamable HTTP transports, routing headers, subscriptions, extension negotiation, JSON Schema 2020-12 preservation, backward-compatible 2025 sessions, bounded callback/session machinery, comprehensive documentation, official conformance gates, and a canonical precommit pipeline. Multiple adversarial review passes surfaced lifecycle, security, validation, concurrency, documentation, and CI defects; all actionable findings were remediated. PR #1 was merged to fork `main` as `519835e`, and post-merge CI run `31360537441` passed all five jobs.

## Sequence of Events

1. Reviewed the earlier MCP Elixir SDK work and established that the existing SDK used OTP but lacked the intended 2.0 protocol surface and evidence.
2. Forked and cloned the SDK into `/home/jmagar/workspace/mcp-elixir-sdk`, then organized implementation into test-first slices.
3. Added specifications, contracts, types, runtime models, ADRs, architecture, tooling guidance, and a progress ledger, including a retroactive record for the first slice.
4. Implemented 2026 routing headers, subscriptions, extension capability negotiation, JSON Schema 2020-12 preservation, client/server wiring, release hardening, and official conformance adapters.
5. Added ADRs for immutable handler configuration, consumer-owned subscription supervision, and the absence of a client result cache.
6. Corrected the protocol scope after the user reaffirmed `2025-11-25` compatibility as a hard requirement; added negotiated downgrade, legacy dispatch, HTTP sessions, callbacks, and dual-era evidence.
7. Ran repeated Lavra and PR reviews; converted findings into Beads and remediated Phoenix mounting, identity binding, supervision, quotas, TTLs, recovery, SSE streaming, capability truthfulness, validation, and callback pressure.
8. Created PR #1 on `jmagar/mcp-elixir-sdk`, corrected an accidentally created upstream PR, addressed all hosted Codex review threads, and resolved them.
9. Passed the local 439-test suite, the full `mix precommit` gate, both official protocol-era conformance paths, and the hosted Elixir/OTP matrix.
10. Merged PR #1 into `main`, synchronized the local checkout, deleted the merged local and remote feature branches, corrected the stale progress ledger, and verified post-merge CI.

## Key Findings

- `Plug.init/1` must return compile-time-escapable configuration; runtime ETS/session ownership moved behind application supervision (`lib/mcp/transport/streamable_http/plug.ex:202`, `lib/mcp/transport/streamable_http/legacy_session_manager.ex:52`).
- MCP session IDs are not authentication credentials. Legacy POST, GET, and DELETE requests must re-resolve and compare the authenticated principal before session use (`lib/mcp/transport/streamable_http/plug.ex`).
- Protocol negotiation is a staged state machine: downgrade and session state are committed only after the complete initialize/initialized exchange, with per-caller deadlines (`lib/mcp/client.ex:1096`).
- Subscription state must exist before the transport can emit an acknowledgment, and worker/open-task failures must cancel and resolve exactly once (`lib/mcp/client.ex:1559`).
- Ports are part of the browser-origin security boundary; configured origins compare normalized scheme, host, and effective port (`lib/mcp/transport/streamable_http/plug.ex:1371`).
- Legacy method dispatch needs method-specific object, `_meta`, required-field, and enum validation; generic JSON-RPC decoding alone cannot prevent callback crashes (`lib/mcp/server/legacy_dispatch.ex`).
- Long-lived SSE must stream incrementally through Req and report terminal listener/session failures rather than buffering or silently stopping (`lib/mcp/transport/streamable_http/client.ex`).
- `subscriptions/listen` results accept only an explicit `resultType: "complete"`; missing or arbitrary values are invalid (`lib/mcp/protocol/messages/subscriptions/listen_result.ex:16`).

## Technical Decisions

- Preserve both protocol eras behind one SDK while keeping the negotiated mode immutable per connection/session.
- Keep durable handler launch configuration immutable and thread request identity explicitly rather than reading mutable global state.
- Put legacy HTTP sessions under a stable OTP manager with global/per-identity limits, idle and absolute expiry, process monitoring, and deterministic cleanup.
- Keep subscriptions consumer-owned, bounded, acknowledgment-first, and explicitly non-resumable; do not add a result cache.
- Enforce negotiated capabilities in both directions and separate 2025 callback semantics from the 2026 stateless core.
- Treat official conformance, the full local suite, Credo, Dialyzer, docs, package audit, JSON validation, and hosted matrices as release evidence rather than relying on implementation claims.

## Files Changed

The implementation range is baseline `2b34b32` through maintenance commit `bf2d4ef`: **151 paths** (**68 created**, **83 modified**). The session artifact itself is the additional created path listed last. No files were renamed or deleted.

### Created

| status | path | previous path | purpose | evidence |
| --- | --- | --- | --- | --- |
| created | `.github/workflows/ci.yml` | — | Hosted test, quality, and dual-era conformance gates | `git diff --name-status 2b34b32..bf2d4ef` |
| created | `.tool-versions` | — | Supported toolchain declaration | same range |
| created | `conformance/README.md` | — | Harness usage and evidence guide | same range |
| created | `conformance/compatibility-2025-11-25.json` | — | 2025 compatibility ledger | same range |
| created | `conformance/scenarios.json` | — | 2026 scenario and evidence ledger | same range |
| created | `docs/adr/0004-immutable-handler-launch-configuration.md` | — | Durable handler configuration decision | same range |
| created | `docs/adr/0005-consumer-owned-subscription-supervision.md` | — | Subscription ownership decision | same range |
| created | `docs/adr/0006-no-client-result-cache-in-2.0.md` | — | No-result-cache decision | same range |
| created | `docs/adr/0007-dual-protocol-era-support.md` | — | Dual-era compatibility decision | same range |
| created | `docs/dev-tooling.md` | — | Development and verification workflow | same range |
| created | `docs/sdk-2.0/contracts.md` | — | Boundary and behavior contracts | same range |
| created | `docs/sdk-2.0/meta-plan.md` | — | Slice progress and release evidence ledger | same range |
| created | `docs/sdk-2.0/runtime-models.md` | — | OTP/runtime state models | same range |
| created | `docs/sdk-2.0/specifications.md` | — | Normative SDK requirements | same range |
| created | `docs/sdk-2.0/types.md` | — | Protocol and internal type definitions | same range |
| created | `docs/sessions/2026-08-08-mcp-elixir-sdk-2.0-routing-subscriptions.md` | — | Earlier implementation session record | same range |
| created | `lib/mcp/client/subscription_handle.ex` | — | Consumer subscription API | same range |
| created | `lib/mcp/client/subscription_worker.ex` | — | Bounded client subscription queue | same range |
| created | `lib/mcp/protocol/extension_capabilities.ex` | — | Extension capability round-trip | same range |
| created | `lib/mcp/protocol/messages/subscriptions/acknowledged_params.ex` | — | Subscription acknowledgment type | same range |
| created | `lib/mcp/protocol/messages/subscriptions/listen_params.ex` | — | Subscription request type | same range |
| created | `lib/mcp/protocol/messages/subscriptions/listen_result.ex` | — | Strict subscription result type | same range |
| created | `lib/mcp/protocol/tool_routing.ex` | — | MCP routing-header derivation | same range |
| created | `lib/mcp/protocol/types/subscription_filter.ex` | — | Subscription filter type | same range |
| created | `lib/mcp/server/legacy_dispatch.ex` | — | 2025 method validation and dispatch | same range |
| created | `lib/mcp/server/notification_collector.ex` | — | Request-scoped notification isolation | same range |
| created | `lib/mcp/server/subscription_publisher.ex` | — | Server publication API | same range |
| created | `lib/mcp/server/subscription_registry.ex` | — | Subscription lookup contract | same range |
| created | `lib/mcp/server/subscription_worker.ex` | — | Supervised server subscription execution | same range |
| created | `lib/mcp/transport/streamable_http/legacy_session.ex` | — | Legacy HTTP request/event correlation | same range |
| created | `lib/mcp/transport/streamable_http/legacy_session_manager.ex` | — | Supervised session ownership, quotas, and expiry | same range |
| created | `package-lock.json` | — | Pinned conformance dependencies | same range |
| created | `package.json` | — | Conformance tooling declaration | same range |
| created | `test/mcp/client/subscription_worker_test.exs` | — | Subscription queue tests | same range |
| created | `test/mcp/client_lifecycle_test.exs` | — | Client concurrency and lifecycle tests | same range |
| created | `test/mcp/client_review_remediation_test.exs` | — | PR review regression tests | same range |
| created | `test/mcp/dual_protocol_compatibility_test.exs` | — | Dual-era client/server integration tests | same range |
| created | `test/mcp/extensions_integration_test.exs` | — | Extension negotiation tests | same range |
| created | `test/mcp/protocol/messages/mrtr_test.exs` | — | MRTR protocol tests | same range |
| created | `test/mcp/protocol/messages/subscriptions_test.exs` | — | Subscription wire-type tests | same range |
| created | `test/mcp/protocol/tool_routing_test.exs` | — | Routing-header unit tests | same range |
| created | `test/mcp/protocol/types/subscription_filter_test.exs` | — | Filter validation tests | same range |
| created | `test/mcp/server/config_test.exs` | — | Configuration and capability tests | same range |
| created | `test/mcp/server/legacy_protocol_hardening_test.exs` | — | Legacy state/validation regression tests | same range |
| created | `test/mcp/server/notification_collector_test.exs` | — | Notification isolation tests | same range |
| created | `test/mcp/server/subscription_worker_test.exs` | — | Server subscription worker tests | same range |
| created | `test/mcp/subscriptions_http_integration_test.exs` | — | Real HTTP subscription integration | same range |
| created | `test/mcp/subscriptions_stdio_integration_test.exs` | — | Stdio subscription integration | same range |
| created | `test/mcp/transport/legacy_session_hardening_test.exs` | — | Session security/lifecycle regressions | same range |
| created | `test/mcp/transport/streamable_http_cache_scope_warning_test.exs` | — | Cache-scope warning tests | same range |
| created | `test/mcp/transport/streamable_http_client_test.exs` | — | HTTP client routing/session tests | same range |
| created | `test/mcp/transport/streamable_http_recovery_test.exs` | — | Session recovery tests | same range |
| created | `test/support/blocking_legacy_handler.ex` | — | Legacy timeout fixture | same range |
| created | `test/support/blocking_transport.ex` | — | Concurrency fixture | same range |
| created | `test/support/client_review_http_plug.ex` | — | HTTP review fixture | same range |
| created | `test/support/client_review_transport.ex` | — | Client review transport fixture | same range |
| created | `test/support/connect_retry_transport.ex` | — | Independent-connect-deadline fixture | same range |
| created | `test/support/delayed_response_plug.ex` | — | Timeout/recovery fixture | same range |
| created | `test/support/eager_subscription_transport.ex` | — | Acknowledgment race fixture | same range |
| created | `test/support/failable_transport.ex` | — | Failure propagation fixture | same range |
| created | `test/support/http_response_plug.ex` | — | HTTP response fixture | same range |
| created | `test/support/legacy_feature_handler.ex` | — | Legacy feature fixture | same range |
| created | `test/support/legacy_mrtr_handler.ex` | — | Legacy MRTR fixture | same range |
| created | `test/support/legacy_session_capture_plug.ex` | — | Session capture fixture | same range |
| created | `test/support/legacy_subscribe_only_handler.ex` | — | Capability truthfulness fixture | same range |
| created | `test/support/request_capture_plug.ex` | — | Routing-header capture fixture | same range |
| created | `test/support/routing_recovery_plug.ex` | — | Downgrade/recovery fixture | same range |
| created | `test/support/subscription_handler.ex` | — | Subscription authorization fixture | same range |
| created | `docs/sessions/2026-08-10-mcp-elixir-sdk-dual-protocol-closeout.md` | — | This complete session record | current save-to-md workflow |

### Modified

| status | path | previous path | purpose | evidence |
| --- | --- | --- | --- | --- |
| modified | `.formatter.exs` | — | Format new source/test inputs | `git diff --name-status 2b34b32..bf2d4ef` |
| modified | `CHANGELOG.md` | — | Accurate dual-era release claims | same range |
| modified | `CLAUDE.md` | — | Era-qualified project rules | same range |
| modified | `README.md` | — | SDK usage, compatibility, and architecture | same range |
| modified | `conformance/client_adapter.exs` | — | Client scenario support | same range |
| modified | `conformance/server_adapter.exs` | — | Server harness lifecycle | same range |
| modified | `conformance/server_handler.ex` | — | Conformance behavior implementation | same range |
| modified | `docs/adr/0002-adopt-2026-07-28-stateless-core-migration.md` | — | Reconcile stateless core with compatibility | same range |
| modified | `docs/adr/0003-2.0.0-conformance-scope.md` | — | Correct scope and landing evidence | same range |
| modified | `docs/adr/README.md` | — | ADR index | same range |
| modified | `docs/architecture.md` | — | Dual-era OTP architecture | same range |
| modified | `docs/implementation-plan.md` | — | Slice sequencing | same range |
| modified | `docs/onboarding.md` | — | Current developer workflow | same range |
| modified | `docs/prd.md` | — | Compatibility requirements | same range |
| modified | `docs/sprint_4_issues.md` | — | Notification hardening record | same range |
| modified | `lib/mcp/client.ex` | — | Negotiation, callbacks, subscriptions, recovery, close semantics | same range |
| modified | `lib/mcp/protocol.ex` | — | Era-aware protocol constants/decoding | same range |
| modified | `lib/mcp/protocol/capabilities/client_capabilities.ex` | — | Negotiated client capability model | same range |
| modified | `lib/mcp/protocol/capabilities/elicitation_capabilities.ex` | — | Serialization cleanup | same range |
| modified | `lib/mcp/protocol/capabilities/prompt_capabilities.ex` | — | Serialization cleanup | same range |
| modified | `lib/mcp/protocol/capabilities/resource_capabilities.ex` | — | Subscription capability truthfulness | same range |
| modified | `lib/mcp/protocol/capabilities/root_capabilities.ex` | — | Serialization cleanup | same range |
| modified | `lib/mcp/protocol/capabilities/server_capabilities.ex` | — | Per-era capability projection | same range |
| modified | `lib/mcp/protocol/capabilities/tool_capabilities.ex` | — | Serialization cleanup | same range |
| modified | `lib/mcp/protocol/error.ex` | — | Controlled protocol errors | same range |
| modified | `lib/mcp/protocol/messages/completion.ex` | — | Type cleanup | same range |
| modified | `lib/mcp/protocol/messages/discover.ex` | — | 2026 discovery semantics | same range |
| modified | `lib/mcp/protocol/messages/elicitation.ex` | — | Type cleanup | same range |
| modified | `lib/mcp/protocol/messages/logging.ex` | — | Type cleanup | same range |
| modified | `lib/mcp/protocol/messages/mrtr.ex` | — | MRTR state/result semantics | same range |
| modified | `lib/mcp/protocol/messages/notification.ex` | — | Type cleanup | same range |
| modified | `lib/mcp/protocol/messages/notifications.ex` | — | Type cleanup | same range |
| modified | `lib/mcp/protocol/messages/prompts.ex` | — | Type cleanup | same range |
| modified | `lib/mcp/protocol/messages/request.ex` | — | Type cleanup | same range |
| modified | `lib/mcp/protocol/messages/resources.ex` | — | Type cleanup | same range |
| modified | `lib/mcp/protocol/messages/response.ex` | — | Type cleanup | same range |
| modified | `lib/mcp/protocol/messages/roots.ex` | — | Type cleanup | same range |
| modified | `lib/mcp/protocol/messages/sampling.ex` | — | Type cleanup | same range |
| modified | `lib/mcp/protocol/messages/tools.ex` | — | Routing/schema behavior | same range |
| modified | `lib/mcp/protocol/meta.ex` | — | Metadata preservation/validation | same range |
| modified | `lib/mcp/protocol/methods.ex` | — | Subscription method constants | same range |
| modified | `lib/mcp/protocol/types/annotations.ex` | — | Encoder cleanup | same range |
| modified | `lib/mcp/protocol/types/content/audio_content.ex` | — | Encoder cleanup | same range |
| modified | `lib/mcp/protocol/types/content/embedded_resource.ex` | — | Encoder cleanup | same range |
| modified | `lib/mcp/protocol/types/content/image_content.ex` | — | Encoder cleanup | same range |
| modified | `lib/mcp/protocol/types/content/resource_link.ex` | — | Encoder cleanup | same range |
| modified | `lib/mcp/protocol/types/content/text_content.ex` | — | Encoder cleanup | same range |
| modified | `lib/mcp/protocol/types/icon.ex` | — | Encoder cleanup | same range |
| modified | `lib/mcp/protocol/types/implementation.ex` | — | Encoder cleanup | same range |
| modified | `lib/mcp/protocol/types/model_preferences.ex` | — | Encoder cleanup | same range |
| modified | `lib/mcp/protocol/types/prompt.ex` | — | Encoder cleanup | same range |
| modified | `lib/mcp/protocol/types/resource.ex` | — | Encoder cleanup | same range |
| modified | `lib/mcp/protocol/types/resource_contents.ex` | — | Encoder cleanup | same range |
| modified | `lib/mcp/protocol/types/resource_template.ex` | — | Encoder cleanup | same range |
| modified | `lib/mcp/protocol/types/root.ex` | — | Encoder cleanup | same range |
| modified | `lib/mcp/protocol/types/tool.ex` | — | JSON Schema 2020-12 preservation | same range |
| modified | `lib/mcp/protocol/types/tool_annotations.ex` | — | Encoder cleanup | same range |
| modified | `lib/mcp/server/config.ex` | — | Per-era capabilities and option validation | same range |
| modified | `lib/mcp/server/connection.ex` | — | Immutable mode, callbacks, subscriptions, close/error handling | same range |
| modified | `lib/mcp/server/dispatch.ex` | — | Handler diagnostics and notification isolation | same range |
| modified | `lib/mcp/server/handler.ex` | — | Handler behavior contracts | same range |
| modified | `lib/mcp/server/tool_context.ex` | — | Identity and request metadata threading | same range |
| modified | `lib/mcp/transport.ex` | — | Close-result contract | same range |
| modified | `lib/mcp/transport/streamable_http/client.ex` | — | Headers, incremental SSE, recovery, detached close | same range |
| modified | `lib/mcp/transport/streamable_http/plug.ex` | — | Phoenix-safe config, auth/session/origin enforcement | same range |
| modified | `lib/mcp_elixir_sdk/application.ex` | — | Session supervision | same range |
| modified | `mix.exs` | — | Dependencies, test support, canonical precommit | same range |
| modified | `mix.lock` | — | Dependency lock updates | same range |
| modified | `test/mcp/client_test.exs` | — | Client behavior coverage | same range |
| modified | `test/mcp/integration_test.exs` | — | Integration expectations | same range |
| modified | `test/mcp/protocol/capabilities_test.exs` | — | Capability round-trip coverage | same range |
| modified | `test/mcp/protocol/messages/discover_test.exs` | — | Discovery coverage | same range |
| modified | `test/mcp/protocol/messages/tools_test.exs` | — | Tool/schema coverage | same range |
| modified | `test/mcp/protocol/meta_test.exs` | — | Metadata coverage | same range |
| modified | `test/mcp/protocol/methods_test.exs` | — | Method registry coverage | same range |
| modified | `test/mcp/protocol/types/tool_test.exs` | — | JSON Schema preservation coverage | same range |
| modified | `test/mcp/protocol_test.exs` | — | Dual-era decode coverage | same range |
| modified | `test/mcp/server/dispatch_test.exs` | — | Dispatch/error coverage | same range |
| modified | `test/mcp/transport/streamable_http_ac_test.exs` | — | Access-control coverage | same range |
| modified | `test/mcp/transport/streamable_http_stateless_test.exs` | — | Stateless and handler-failure coverage | same range |
| modified | `test/support/echo_handler.ex` | — | Integration fixture behavior | same range |
| modified | `test/support/mock_transport.ex` | — | Concurrent transport fixture behavior | same range |
| modified | `test/support/stateless_handler.ex` | — | Failure/notification test modes | same range |

## Beads Activity

| ID | Title | Actions observed | Final status | Why it mattered |
| --- | --- | --- | --- | --- |
| `mcp-elixir-sdk-7yz` | Dual protocol compatibility Lavra remediation | Created, tracked, closed; final merge/CI comment added during maintenance | closed | Parent record for the complete adversarial remediation |
| `mcp-elixir-sdk-7yz.1` | Make legacy HTTP sessions Phoenix-safe and supervised | Created, commented with lessons/checks, closed | closed | Prevented compiled Plug failure and immortal unsupervised sessions |
| `mcp-elixir-sdk-7yz.2` | Bind legacy sessions to the authenticated principal | Created, commented, closed | closed | Prevented cross-principal use of leaked session IDs |
| `mcp-elixir-sdk-7yz.3` | Repair legacy client negotiation and recovery state | Created, commented, closed | closed | Made downgrade, readiness, and session recovery coherent |
| `mcp-elixir-sdk-7yz.4` | Preserve protocol mode and truthful capabilities | Created, commented, closed | closed | Kept era state immutable and capabilities enforceable |
| `mcp-elixir-sdk-7yz.5` | Validate all legacy request boundaries | Created, commented, closed | closed | Converted malformed requests into `-32602` instead of crashes |
| `mcp-elixir-sdk-7yz.6` | Bound and clean legacy HTTP waiters | Created, commented, closed | closed | Removed leaked waiters, reserved IDs, and unbounded buffers |
| `mcp-elixir-sdk-7yz.7` | Stream and recover the legacy SSE client | Created, commented, closed | closed | Replaced buffered GET behavior with incremental SSE and recovery |
| `mcp-elixir-sdk-7yz.8` | Bound client callbacks and legacy MRTR resolution | Created, commented, closed | closed | Added admission limits, deadlines, and overload behavior |
| `mcp-elixir-sdk-7yz.9` | Correct compatibility claims and review hygiene | Created, commented, closed | closed | Kept release claims aligned with actual evidence |

## Repository Maintenance

- **Plans:** `find docs/plans -maxdepth 2 -type f` returned no files. No plan was moved, and no ambiguous plan was hidden.
- **Beads:** `bd list` and `bd show` confirmed the parent and nine children were closed. A final comment was added to `mcp-elixir-sdk-7yz` recording merge commit `519835e`, post-merge run `31360537441`, and 439/439 local tests. No new follow-up bead was required because the only remaining decision is release timing.
- **Worktrees and branches:** `git worktree list --porcelain` showed one clean normal worktree. `git merge-base --is-ancestor origin/codex/mcp-routing-headers origin/main` returned zero, proving the remote branch was merged; the local branch had already been deleted and the remote branch was then deleted. Upstream branches were left untouched because they are not owned by this fork-maintenance workflow.
- **Stale docs:** `docs/sdk-2.0/meta-plan.md` incorrectly said hosted verification and merge were pending. Commit `bf2d4ef` updates it with merge commit `519835e`, successful run `31360537441`, and the remaining tag/Hex release gate.
- **Transparency:** The earlier incorrectly targeted upstream PR was closed rather than modified further. CodeRabbit skipped the 149-file PR because it exceeded its 100-file limit, and Cubic skipped pending quota confirmation; internal, Lavra, hosted Codex, local static analysis, and CI reviews supplied the actionable evidence instead.

## Tools and Skills Used

- **Shell and file tools:** `rg`, `git`, `mix`, `npm`, `jq`, file reads, and patch-based edits were used for repository inspection, implementation, tests, documentation, and safe cleanup. Long-running commands were polled; no destructive reset or broad cleanup was used.
- **Elixir/OTP tooling:** ExUnit, Credo, Dialyzer, ExDoc, Hex build/audit, Plug, Bandit, Req, and OTP supervisors/registries verified implementation and packaging.
- **GitHub CLI and hosted services:** `gh` created/closed the appropriate PRs, read review threads and checks, resolved fixed threads, merged fork PR #1, and monitored CI. CodeRabbit and Cubic produced only skip notices; hosted Codex produced four actionable inline findings.
- **Skills/plugins:** Elixir guidance, `lavra:lavra-review`, `vibin:quick-push`, `vibin:review-pr`, `superpowers:finishing-a-development-branch`, and `vibin:save-to-md` governed implementation review, landing, merge verification, and this record.
- **Agents/subagents:** Specialized client, server, security, data-integrity, history/docs, code-review, and simplification agents independently reviewed bounded areas. Their findings were reproduced before remediation when feasible and reconciled in the shared worktree.
- **External documentation:** Official MCP lifecycle/authorization/transport/conformance material plus Plug and Req streaming behavior were consulted. Earlier generated documentation was treated as design input, not implementation evidence.

## Commands Executed

| Command | Result |
| --- | --- |
| `mix test --seed 0` | Final local suite passed: 439 tests, 0 failures |
| `mix precommit` | Formatting, compile, tests, Credo, Dialyzer, docs, Hex, audit, dependency, JSON, and diff gates passed |
| `npx @modelcontextprotocol/conformance ... --requirements 2025-11-25` | 2025 server denominator passed 81/81 |
| Official 2026 server/client conformance commands | Scored server checks and required client matrix passed |
| `gh pr view 1 --repo jmagar/mcp-elixir-sdk ...` | Confirmed fork PR open/mergeable/green, later merged |
| `gh api graphql ... resolveReviewThread` | Resolved all four hosted Codex review threads after fixes |
| `gh pr merge 1 --repo jmagar/mcp-elixir-sdk --merge` | Merged PR #1 as `519835e` |
| `gh run watch 31360537441 --exit-status` | Post-merge quality, conformance, and three test jobs passed |
| `git merge-base --is-ancestor origin/codex/mcp-routing-headers origin/main` | Returned 0; proved feature branch was safe to remove |
| `git push origin --delete codex/mcp-routing-headers` | Removed the merged remote feature branch |

## Errors Encountered

- A Plug configuration containing an ETS reference could not be escaped through `Plug.Builder`; runtime ownership moved to supervised application processes.
- An early PR was created against the upstream repository rather than the user's fork; it was closed, and fork PR #1 became the canonical PR.
- Focused review testing exposed a server test fixture using a module instead of `{module, opts}`; the fixture was corrected.
- A subscription-worker exit attempted synchronous cancellation through a deliberately blocking fixture and crashed it; opening subscriptions now cancel the open task and resolve the caller without that unsafe send.
- Full-suite concurrency exposed 100 ms authorization timing and initialization ordering assumptions; tests were changed to explicit bounded synchronization rather than rerun-only acceptance.
- Credo found close-path style/nesting and missing-alias issues; behavior-preserving refactors cleared them.
- Dialyzer rejected a guard over opaque `URI.authority`; explicit-port detection now uses the original origin string while retaining exact port semantics.

## Behavior Changes (Before/After)

| Area | Before | After |
| --- | --- | --- |
| Protocol support | 2026-only cutover at one point in the work | Explicit `2026-07-28` core plus negotiated `2025-11-25` compatibility |
| Phoenix mounting | `Plug.init/1` returned a runtime ETS reference | Plug options are compile-safe; runtime state is supervised |
| Legacy authorization | Session ID alone selected the original identity | Every session request re-authenticates and compares identity |
| Session lifecycle | Unsupervised, unbounded, DELETE/lazy cleanup | Supervised quotas, TTLs, monitors, and endpoint cleanup |
| Client downgrade | Limited JSON-RPC fallback with premature state commits | HTTP 400 downgrade, staged readiness, idempotent connect, bounded recovery |
| Legacy SSE | Buffered `Req.get/2`, silent terminal stop | Incremental streaming, paced retry, terminal signal, session recovery |
| Capabilities | Some advertised or invoked paths were not negotiated | Per-era truthful advertisement and bidirectional enforcement |
| Legacy validation | Scalars or malformed `_meta` could crash sessions | Controlled invalid-params responses; session remains usable |
| Callback pressure | Unlimited callback tasks and missing deadlines | Dedicated bounded supervisors, quotas, deadlines, overload errors |
| Subscriptions | Acknowledgment/open races and async-close test races | Provisional registration, exact completion, bounded synchronization |
| Close/errors | Some transport and manager failures were hidden | Public APIs propagate failures and handlers log diagnostics |
| Release evidence | Claims and ledgers drifted from implementation | 439-test, dual-era conformance, static, package, and hosted evidence recorded |

## Verification Evidence

| Command | Expected | Actual | Status |
| --- | --- | --- | --- |
| `mix test --seed 0` | Full suite green | 439 tests, 0 failures | pass |
| `mix compile --warnings-as-errors` | No compile warnings | Passed | pass |
| `mix credo --strict` | No findings | 1608 mods/funs, no issues | pass |
| `mix dialyzer` | Zero type errors | Total errors: 0 | pass |
| `mix docs` / `mix hex.build` | Docs and package build | Passed | pass |
| `mix hex.audit` | No retired/advisory packages | None found | pass |
| `jq empty` on both conformance ledgers | Valid JSON | Passed | pass |
| 2025 official server conformance | Full denominator | 81/81 | pass |
| 2026 scored server conformance | All scored checks | 120/120 | pass |
| Required 2026 client matrix | All required checks | 63/63 | pass |
| PR-head CI run `31348324598` | All jobs green | Quality, conformance, three test jobs passed | pass |
| Post-merge CI run `31360537441` | Merge commit green | All five jobs passed | pass |
| `git status --short --branch` after merge | Clean synchronized main | `## main...origin/main` | pass |

## Risks and Rollback

- The change is a large 2.0 development line spanning protocol, transports, OTP lifecycle, and public behavior. A rollback should revert merge commit `519835e` on fork `main`; do not rewrite published history.
- `bf2d4ef` is documentation-only and can be reverted independently if its evidence becomes stale.
- Dual-era support increases state-machine surface. Preserve the 439-test suite, both conformance ledgers, and hosted matrix when changing negotiation or session code.
- The current version remains `2.0.0-dev.2`; publishing requires an explicit tag/Hex decision and should not be inferred from merge completion.

## Decisions Not Taken

- Did not retain the temporary 2026-only restriction because 2025 compatibility was an explicit hard requirement.
- Did not use an ETS reference in compiled Plug configuration or leave legacy session processes unsupervised.
- Did not treat a session ID as sufficient authorization or permit configurable origins to ignore ports.
- Did not add a client result cache; ADR-0006 preserves that boundary.
- Did not force-push, reset, delete unmerged/unknown worktrees, or modify upstream-owned branches.
- Did not count CodeRabbit/Cubic skip notices as successful substantive review.

## References

- [Fork PR #1](https://github.com/jmagar/mcp-elixir-sdk/pull/1)
- [Post-merge CI run 31360537441](https://github.com/jmagar/mcp-elixir-sdk/actions/runs/31360537441)
- [MCP 2025-11-25 specification](https://modelcontextprotocol.io/specification/2025-11-25)
- [MCP 2026-07-28 specification](https://modelcontextprotocol.io/specification/2026-07-28)
- `docs/sdk-2.0/specifications.md`
- `docs/sdk-2.0/contracts.md`
- `docs/sdk-2.0/meta-plan.md`
- `docs/adr/0004-immutable-handler-launch-configuration.md`
- `docs/adr/0005-consumer-owned-subscription-supervision.md`
- `docs/adr/0006-no-client-result-cache-in-2.0.md`
- `docs/adr/0007-dual-protocol-era-support.md`

## Open Questions

- When should `2.0.0-dev.2` advance to a release candidate or final `2.0.0` tag?
- Should the completed fork work be proposed upstream in smaller reviewable PRs, given the original 149-file PR exceeded CodeRabbit's review limit?

## Next Steps

- **Unfinished from this session:** none; implementation, review remediation, merge, branch cleanup, and post-merge verification are complete.
- **Follow-on not started:** decide release versioning, prepare release notes from the verified ledgers, and publish to Hex only after an explicit release decision.
- **Optional upstreaming:** split the merged fork delta into bounded upstream PRs if contribution is desired.
- **Immediate verification before release:** run `mix precommit`, both protocol-era conformance gates, and confirm the hosted matrix remains green on the release commit.
