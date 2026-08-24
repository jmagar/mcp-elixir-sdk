---
date: 2026-08-24 14:38:40 EDT
repo: git@github.com:jmagar/mcp-elixir-sdk.git
branch: main
head: 3576cdaf8ce622de61c56ff614359ca92a97a0e5
session id: c0ad640b-57db-4d9c-8640-97be2b719622
transcript: /home/jmagar/.claude/projects/-home-jmagar-workspace-mcp-elixir-sdk/c0ad640b-57db-4d9c-8640-97be2b719622.jsonl
working directory: /home/jmagar/workspace/mcp-elixir-sdk
worktree: /home/jmagar/workspace/mcp-elixir-sdk
pr: "#6 feat: harden SDK boundaries and add browser interoperability evidence (https://github.com/jmagar/mcp-elixir-sdk/pull/6)"
beads: mcp-elixir-sdk-bxw, mcp-elixir-sdk-rn8
---

# SDK full review and remediation

## User Request

Review the entire SDK with Lavra, fix every issue found, complete the open-type and real-host browser interoperability tasks, commit and publish the work, run Vibin and Phoenix reviews to closure, and merge the resulting PR.

## Session Overview

The SDK received a full architecture, security, performance, reliability, testing, and public-API review. All actionable findings were remediated, the two requested Beads were closed, PR #6 was created and repeatedly re-reviewed at exact heads, all local and hosted gates passed, and the PR was merged into `main` as `3576cdaf`.

## Sequence of Events

1. Reviewed the SDK across architecture, security, performance, API compatibility, test coverage, and silent-failure behavior.
2. Implemented bounded execution, pagination, notification, SSE, state-handle, subprocess, session, and transport-delivery behavior with regression tests.
3. Audited all schema-open MCP Result/Error boundaries and added lossless unknown-member preservation and collision/JSON-safety tests.
4. Added an Official Inspector browser interoperability workflow with policy, resource hydration, same-server callback, final iframe state, screenshots, console, network, and failure-report evidence.
5. Created and pushed PR #6, ran Vibin review iterations, fixed every surfaced issue, then ran Phoenix review iterations and fixed its compatibility and documentation findings.
6. Verified exact-head CI, merged PR #6, fast-forwarded local `main`, and removed only proven-merged session branches/worktrees.

## Key Findings

- `lib/mcp/server/connection.ex` previously ran consumer callbacks synchronously, mishandled some first-valid-request mode selection and duplicate IDs, and ignored several transport send failures.
- `lib/mcp/client.ex` had unbounded/quadratic `list_all_*` pagination and no generic pending-request admission limit.
- `lib/mcp/server/state_handle.ex` lacked expiry, capacity, principal binding, and atomic consumption; remediation preserved the idempotent `delete/2` public contract while adding checked `delete/3`.
- `lib/mcp/transport/streamable_http/client.ex` could retain stale legacy readiness after asynchronous SSE session expiry.
- Schema-open result/error types did not consistently preserve unknown string-key JSON members; `test/mcp/protocol/open_type_audit_test.exs` now exercises the contract centrally.

## Technical Decisions

- Handler callbacks use bounded monitored tasks with deadlines so a slow consumer cannot block the connection GenServer.
- Open objects preserve vendor fields through a shared merge boundary that rejects known-key collisions, non-string keys, and non-JSON values.
- State handles have TTL/capacity/principal controls and atomic consume, while legacy `delete/2` remains idempotent for compatibility.
- Browser interoperability remains a separate CI job but runs on every PR because transport/server/protocol changes can affect Apps behavior.
- README and usage rules pin the fully reviewed implementation commit `e9c7fb89` rather than a mutable branch.

## Files Changed

The PR changed 80 files. `A` means created and `M` means modified.

| status | path | previous path | purpose | evidence |
|---|---|---|---|---|
| M | `.github/workflows/ci.yml` | — | CI trigger and verification updates | PR diff |
| A | `.github/workflows/mcp-apps-browser-interop.yml` | — | Official Inspector browser job | hosted job passed |
| M | `.gitignore` | — | generated browser evidence exclusions | PR diff |
| M | `README.md` | — | reviewed install pin and SDK guidance | exact SHA aligned |
| M | `conformance/README.md` | — | browser/conformance instructions | PR diff |
| A | `conformance/apps_browser_adapter.exs` | — | Inspector adapter fixture | browser CI |
| A | `conformance/apps_browser_handler.ex` | — | Apps fixture server/callback | browser CI |
| A | `conformance/apps_browser_interop.mjs` | — | Playwright Inspector scenario | browser CI |
| A | `conformance/apps_browser_report.mjs` | — | deterministic pass/failure report | unit tested |
| A | `conformance/apps_browser_report.test.mjs` | — | report regression tests | 2 passed |
| A | `conformance/browser/package-lock.json` | — | browser dependency lock | npm CI |
| A | `conformance/browser/package.json` | — | Playwright fixture manifest | npm CI |
| M | `conformance/mcp-apps-2026-01-26.json` | — | Apps evidence ledger | quality CI |
| M | `docs/adr/0009-mcp-apps-support.md` | — | browser evidence architecture | docs passed |
| M | `docs/dev-tooling.md` | — | verification workflow | docs passed |
| M | `docs/sdk-2.0/types.md` | — | open-object contracts | docs passed |
| A | `examples/quickstart_server.exs` | — | packaged executable example | package smoke |
| M | `lib/mcp/client.ex` | — | bounds, pagination, expiry recovery | tests passed |
| M | `lib/mcp/client/subscription_worker.ex` | — | preserve terminal result | tests passed |
| M | `lib/mcp/protocol.ex` | — | open-object protocol surface | tests passed |
| M | `lib/mcp/protocol/capabilities/client_capabilities.ex` | — | open fields/types | audit passed |
| M | `lib/mcp/protocol/capabilities/server_capabilities.ex` | — | open fields/types | audit passed |
| M | `lib/mcp/protocol/error.ex` | — | lossless error extras/data semantics | audit passed |
| M | `lib/mcp/protocol/messages/completion.ex` | — | open result preservation | audit passed |
| M | `lib/mcp/protocol/messages/discover.ex` | — | open result preservation | audit passed |
| M | `lib/mcp/protocol/messages/elicitation.ex` | — | open result preservation | audit passed |
| M | `lib/mcp/protocol/messages/prompts.ex` | — | open result preservation | audit passed |
| M | `lib/mcp/protocol/messages/resources.ex` | — | open result preservation | audit passed |
| M | `lib/mcp/protocol/messages/resources/directory_read_result.ex` | — | open result preservation | audit passed |
| M | `lib/mcp/protocol/messages/roots.ex` | — | open result preservation | audit passed |
| M | `lib/mcp/protocol/messages/sampling.ex` | — | open result preservation | audit passed |
| M | `lib/mcp/protocol/messages/skills/get_result.ex` | — | open result preservation | audit passed |
| M | `lib/mcp/protocol/messages/skills/list_result.ex` | — | open result preservation | audit passed |
| M | `lib/mcp/protocol/messages/subscriptions/listen_result.ex` | — | open result preservation | audit passed |
| M | `lib/mcp/protocol/messages/tools.ex` | — | open result preservation | audit passed |
| M | `lib/mcp/protocol/types/content/resource_link.ex` | — | open type preservation | audit passed |
| M | `lib/mcp/protocol/types/resource.ex` | — | open type preservation | audit passed |
| M | `lib/mcp/protocol/types/resource_contents.ex` | — | open type preservation | audit passed |
| M | `lib/mcp/protocol/types/resource_template.ex` | — | open type preservation | audit passed |
| M | `lib/mcp/protocol/types/tool.ex` | — | open type preservation | audit passed |
| M | `lib/mcp/server/config.ex` | — | normalize handler init failures | tests passed |
| M | `lib/mcp/server/connection.ex` | — | bounded handlers and protocol delivery | tests passed |
| M | `lib/mcp/server/handler.ex` | — | handler contracts | tests passed |
| M | `lib/mcp/server/notification_collector.ex` | — | count/byte budgets | tests passed |
| M | `lib/mcp/server/state_handle.ex` | — | TTL, capacity, identity, atomic consume | tests passed |
| M | `lib/mcp/transport/sse.ex` | — | bounded linear parsing | tests passed |
| M | `lib/mcp/transport/stdio/process.ex` | — | cleanup diagnostics/propagation | tests passed |
| A | `lib/mcp/transport/stdio/signal.ex` | — | bounded OS signal execution | tests passed |
| M | `lib/mcp/transport/streamable_http/client.ex` | — | legacy expiry invalidation | tests passed |
| M | `lib/mcp/transport/streamable_http/legacy_session_manager.ex` | — | authorization freshness | tests passed |
| M | `lib/mcp/transport/streamable_http/plug.ex` | — | identity and bounded HTTP dispatch | tests passed |
| M | `mix.exs` | — | Bandit security update/package inputs | audit passed |
| A | `scripts/package_smoke.exs` | — | unpacked-package verification | CI passed |
| A | `test/examples/quickstart_server_test.exs` | — | example contract | suite passed |
| M | `test/mcp/client/subscription_worker_test.exs` | — | terminal race regression | suite passed |
| M | `test/mcp/client_lifecycle_test.exs` | — | client task lifecycle coverage | suite passed |
| M | `test/mcp/client_review_remediation_test.exs` | — | bounds and expiry regressions | suite passed |
| M | `test/mcp/client_test.exs` | — | client behavior coverage | suite passed |
| M | `test/mcp/dual_protocol_compatibility_test.exs` | — | protocol-era coverage | suite passed |
| M | `test/mcp/protocol/error_test.exs` | — | error round-trip coverage | suite passed |
| M | `test/mcp/protocol/messages/resources_directory_test.exs` | — | directory open-object coverage | suite passed |
| M | `test/mcp/protocol/messages/skills_test.exs` | — | skills open-object coverage | suite passed |
| A | `test/mcp/protocol/open_type_audit_test.exs` | — | table-driven open-type audit | suite passed |
| M | `test/mcp/server/config_test.exs` | — | init exception/error coverage | suite passed |
| M | `test/mcp/server/legacy_protocol_hardening_test.exs` | — | async, duplicate, delivery regressions | suite passed |
| M | `test/mcp/server/notification_collector_test.exs` | — | notification budget coverage | suite passed |
| M | `test/mcp/server/state_handle_test.exs` | — | handle security/bounds coverage | suite passed |
| M | `test/mcp/subscriptions_stdio_integration_test.exs` | — | subscription integration | suite passed |
| M | `test/mcp/transport/legacy_session_hardening_test.exs` | — | authorization freshness | suite passed |
| M | `test/mcp/transport/sse_test.exs` | — | fragmentation/bound coverage | suite passed |
| A | `test/mcp/transport/stdio_fixture_test.exs` | — | subprocess fixture contract | suite passed |
| M | `test/mcp/transport/stdio_security_test.exs` | — | cleanup security regressions | suite passed |
| A | `test/mcp/transport/stdio_signal_test.exs` | — | signal result regressions | suite passed |
| M | `test/mcp/transport/stdio_test.exs` | — | stdio behavior coverage | suite passed |
| M | `test/mcp/transport/streamable_http_stateless_test.exs` | — | HTTP callback/bounds coverage | suite passed |
| M | `test/support/mock_transport.ex` | — | transport failure fixtures | suite passed |
| M | `test/support/stateless_handler.ex` | — | failure/notification fixtures | suite passed |
| A | `test/support/stdio_fixture.ex` | — | controlled stdio subprocess | suite passed |
| M | `test/support/subscription_handler.ex` | — | blocking/duplicate fixtures | suite passed |
| M | `usage-rules.md` | — | reviewed immutable dependency pin | exact SHA aligned |

## Beads Activity

| id | title | actions | final status | why it mattered |
|---|---|---|---|---|
| `mcp-elixir-sdk-bxw` | Audit unknown-field preservation across all MCP open types | claimed, implemented, verified, closed | closed | established forward-compatible lossless open-object behavior |
| `mcp-elixir-sdk-rn8` | Add optional real-host MCP Apps browser interoperability job | claimed, implemented, verified, closed | closed | supplied real Official Inspector browser evidence |

## Repository Maintenance

- **Plans:** `find docs/plans -maxdepth 2 -type f` returned no files, so no completed plan was moved.
- **Beads:** `bd show` confirmed both session Beads closed with explicit completion reasons; no remaining session work justified a new follow-up Bead.
- **Worktrees/branches:** removed the clean merged `codex/mcp-apps` worktree/local branch and its remote branch after `git merge-base --is-ancestor` returned success. Fast-forwarded local `main` to `3576cdaf`, deleted the merged local SDK review branch, and pruned its already-deleted remote tracking ref.
- **Unrelated refs:** older `codex/mcp-skills`, `codex/natural-exit-cleanup`, `codex/tri-version-secure-transports`, `review/pr-2`, and `spec/sep2640` refs were left untouched because they were outside this session and ownership/obsolescence was not established.
- **Stale docs:** README and usage rules were aligned to the same reviewed immutable SHA during Phoenix remediation; no further contradicted session documentation was observed.

## Tools and Skills Used

- **Skills/plugins:** `lavra:lavra-review`, `vibin:review-pr`, `elixir-phoenix:phx-review`, and `vibin:save-to-md` drove review, remediation, exact-head re-review, and closeout requirements.
- **Subagents:** architecture, security, performance, code-review, silent-failure, and test/CI lanes reviewed independent surfaces and returned concrete findings; all were re-run to clean verdicts.
- **Shell/file tools:** `git`, `rg`, `mix`, `node`, `npm`, `actionlint`, `bd`, and patch-based editing were used for inspection, implementation, maintenance, and verification.
- **GitHub CLI:** created/inspected PR #6, monitored exact-head checks, merged the PR, and verified the merge commit.
- **Browser tooling:** Playwright drove the Official MCP Inspector; hosted evidence captured DOM completion, screenshots, console errors, network failures, host version, and policy metadata.

## Commands Executed

| command | result |
|---|---|
| `mix test --seed 0` | 607 tests, 0 failures |
| `mix compile --warnings-as-errors` | passed |
| `mix credo --strict` | 2,416 mods/functions, no issues |
| `mix dialyzer` | 0 errors |
| `mix docs` | generated successfully |
| `mix run scripts/package_smoke.exs` | unpacked package example passed |
| `mix hex.audit` | no retired/advisory packages |
| `node --test conformance/apps_browser_report.test.mjs` | 2 passed |
| `actionlint .github/workflows/*.yml` | passed |
| `gh pr checks 6 --repo jmagar/mcp-elixir-sdk` | all required hosted checks passed |
| `gh pr merge 6 --merge --delete-branch` | merged as `3576cdaf` |

## Errors Encountered

- An early focused client test alternated between `:session_expired` and `:not_ready` because asynchronous invalidation races with the correlated request result. The regression was corrected to accept both truthful terminal states while asserting bounded recovery counts.
- One 100 ms HTTP test assertion was timing-sensitive; it was given an explicit bounded timeout and later exact-head suites were stable.
- The first remote branch deletion after merge reported that the ref did not exist; `git fetch --prune origin` confirmed GitHub had already deleted it.
- The injected transcript path belongs to an older 2026-08-10 Claude session. It was inspected as required but was not treated as evidence for this conversation; current-session facts came from Git, PR, Beads, command output, and the live conversation context.

## Behavior Changes (Before/After)

| area | before | after |
|---|---|---|
| Server callbacks | slow handlers blocked an entire connection | bounded monitored tasks preserve responsiveness |
| Client pagination | unlimited/cyclic and potentially quadratic | page/item/cursor/deadline bounded and linear |
| State handles | unbounded global bearer values | TTL/capacity/principal binding and atomic consume |
| Open protocol types | unknown members inconsistently lost | unknown JSON members round-trip with collision safety |
| Legacy SSE expiry | high-level client could remain falsely ready | expiry invalidates readiness, including concurrent requests |
| Browser evidence | no real-host pre-merge gate | Official Inspector job verifies full embedded-app completion |
| Transport delivery | several failures were silently ignored | send/signal/cleanup failures propagate deterministically |

## Verification Evidence

| command | expected | actual | status |
|---|---|---|---|
| Full local suite | all tests pass | 607/607 passed | pass |
| Three hosted runtime matrices | all pass | all passed | pass |
| Constrained hosted suite | all pass | 607/607 passed | pass |
| Conformance | all scenarios pass | 81 passed, 0 failed | pass |
| Official Inspector host | app reaches final state without diagnostics | passed in 1m28s | pass |
| Credo/Dialyzer/docs/package/audit | no release blockers | all passed | pass |
| Exact remote head | local and remote match | `ecd3cb2f` before merge | pass |
| Merge verification | PR merged into `main` | `3576cdaf` | pass |

## Risks and Rollback

- The changes touch core protocol, client, server, and transport paths. Regression risk is mitigated by 607 tests across three runtime matrices, constrained CI, conformance, and real-browser evidence.
- Roll back the merge with `git revert -m 1 3576cdaf8ce622de61c56ff614359ca92a97a0e5`; do not rewrite `main` history.
- Browser workflow dependencies are isolated under `conformance/browser` and are excluded from the Hex package.

## Decisions Not Taken

- Did not keep synchronous handler execution for ordering; independent requests require connection responsiveness, and bounded task correlation preserves protocol semantics.
- Did not make browser evidence dispatch-only or path-filtered; realistic regressions originate across server, protocol, and transport code.
- Did not change `StateHandle.delete/2` to checked failure semantics; compatibility requires idempotent cleanup, so checked behavior lives in `delete/3`.
- Did not delete unrelated historical branches because this session did not establish their ownership or obsolescence.

## References

- PR #6: https://github.com/jmagar/mcp-elixir-sdk/pull/6
- Merge commit: https://github.com/jmagar/mcp-elixir-sdk/commit/3576cdaf8ce622de61c56ff614359ca92a97a0e5
- Final reviewed implementation: https://github.com/jmagar/mcp-elixir-sdk/commit/e9c7fb8927de1d54c74ffecd21bfed63ba1a19ef
- Official Inspector workflow run: https://github.com/jmagar/mcp-elixir-sdk/actions/runs/32762873251
- Exact-head CI run: https://github.com/jmagar/mcp-elixir-sdk/actions/runs/32762873260

## Next Steps

- No unfinished work from this session remains.
- Use `main` at or after `3576cdaf` for subsequent development.
- If releasing `2.0.0-rc.1`, rerun the existing release/package gates from the intended release commit and update immutable install pins deliberately.
