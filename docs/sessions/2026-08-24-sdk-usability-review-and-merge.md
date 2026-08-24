---
date: 2026-08-24 14:39:41 EST
repo: git@github.com:jmagar/mcp-elixir-sdk.git
branch: main
head: 3576cdaf8ce622de61c56ff614359ca92a97a0e5
working directory: /home/jmagar/workspace/mcp-elixir-sdk
worktree: /home/jmagar/workspace/mcp-elixir-sdk
pr: "#6 feat: harden SDK boundaries and add browser interoperability evidence (https://github.com/jmagar/mcp-elixir-sdk/pull/6)"
---

# SDK usability, review remediation, and merge

## User Request

Make the SDK easier to use, address all full-suite and review findings, commit and push the work, create and merge a PR, run both `elixir-phoenix:phx-review` and `vibin:review-pr`, and leave the repository synchronized and clean.

## Session Overview

The session completed SDK 2.0 usability documentation, forward-compatible protocol types, transport and lifecycle hardening, executable package/browser evidence, two structured review cycles, and exact-head CI verification. PR #6 merged to `main` as `3576cdaf`; its reviewed head was `ecd3cb2f`.

## Sequence of Events

1. Audited the SDK surface and corrected stale usage guidance with an executable quickstart and package smoke test.
2. Closed client, server, HTTP, SSE, subscription, shared-state, and stdio cleanup failures exposed by focused and full-suite runs.
3. Added lossless schema-open result handling and MCP Apps browser interoperability evidence.
4. Opened PR #6, ran `phx-review`, fixed every finding, and pushed the remediation commits.
5. Ran `vibin:review-pr` across correctness, tests, silent failures, types, comments, and simplification; fixed every actionable result and repeated review until clean.
6. Verified 607 local tests and every exact-head GitHub job, then merged PR #6 and synchronized `main`.

## Key Findings

- Legacy SSE expiry could leave cached initialization valid while requests were pending; deferred invalidation now completes on success, timeout, or transport failure (`lib/mcp/client.ex`).
- Ordinary concurrent requests could reuse a JSON-RPC ID; the server now rejects duplicate in-flight IDs (`lib/mcp/server/connection.ex`).
- Stdio cleanup could report stale TERM failures after successful KILL, discard real signal diagnostics, or race late descendants (`lib/mcp/transport/stdio/process.ex`).
- Several typed protocol results and JSON-RPC Error were not fully lossless; unknown members and absent-versus-null error data are now preserved (`lib/mcp/protocol`).
- Browser evidence previously represented only the success path; generated reports now record pass/failure truthfully and have negative-path Node tests (`conformance/apps_browser_report.mjs`).

## Technical Decisions

- Preserve unknown schema-open fields in a typed `extra_fields()` map constrained to JSON string keys and JSON values.
- Bind legacy HTTP sessions to verified identity plus an explicitly supplied stable authorization context, not volatile handler options.
- Treat verified process absence as successful cleanup while retaining bounded `/bin/kill` diagnostics when confirmation genuinely fails.
- Keep the browser interoperability workflow separate from package CI while still requiring exact Inspector-host evidence on the PR.
- Use immutable reviewed commit coordinates in unreleased installation guidance and label them as snapshots rather than `main`.

## Files Changed

Every path below is from `git diff --name-status aabe652d..ecd3cb2f`.

| Status | Path(s) | Previous path | Purpose | Evidence |
|---|---|---|---|---|
| modified | `.github/workflows/ci.yml`, `.gitignore`, `mix.exs` | — | CI and package boundaries | merged PR diff |
| created | `.github/workflows/mcp-apps-browser-interop.yml`, `scripts/package_smoke.exs`, `examples/quickstart_server.exs` | — | executable release/browser evidence | merged PR diff |
| modified | `README.md`, `usage-rules.md`, `conformance/README.md`, `conformance/mcp-apps-2026-01-26.json`, `docs/adr/0009-mcp-apps-support.md`, `docs/dev-tooling.md`, `docs/sdk-2.0/types.md` | — | accurate SDK and conformance guidance | merged PR diff |
| created | `conformance/apps_browser_adapter.exs`, `conformance/apps_browser_handler.ex`, `conformance/apps_browser_interop.mjs`, `conformance/apps_browser_report.mjs`, `conformance/apps_browser_report.test.mjs`, `conformance/browser/package.json`, `conformance/browser/package-lock.json` | — | MCP Apps browser fixture and evidence | merged PR diff |
| modified | `lib/mcp/client.ex`, `lib/mcp/client/subscription_worker.ex` | — | client lifecycle and subscription reliability | merged PR diff |
| modified | `lib/mcp/protocol.ex`, `lib/mcp/protocol/error.ex`, `lib/mcp/protocol/capabilities/client_capabilities.ex`, `lib/mcp/protocol/capabilities/server_capabilities.ex` | — | shared open-object and error contracts | merged PR diff |
| modified | `lib/mcp/protocol/messages/completion.ex`, `lib/mcp/protocol/messages/discover.ex`, `lib/mcp/protocol/messages/elicitation.ex`, `lib/mcp/protocol/messages/prompts.ex`, `lib/mcp/protocol/messages/resources.ex`, `lib/mcp/protocol/messages/resources/directory_read_result.ex`, `lib/mcp/protocol/messages/roots.ex`, `lib/mcp/protocol/messages/sampling.ex`, `lib/mcp/protocol/messages/skills/get_result.ex`, `lib/mcp/protocol/messages/skills/list_result.ex`, `lib/mcp/protocol/messages/subscriptions/listen_result.ex`, `lib/mcp/protocol/messages/tools.ex` | — | lossless typed result boundaries | merged PR diff |
| modified | `lib/mcp/protocol/types/content/resource_link.ex`, `lib/mcp/protocol/types/resource.ex`, `lib/mcp/protocol/types/resource_contents.ex`, `lib/mcp/protocol/types/resource_template.ex`, `lib/mcp/protocol/types/tool.ex` | — | JSON-safe unknown-field preservation | merged PR diff |
| modified | `lib/mcp/server/config.ex`, `lib/mcp/server/connection.ex`, `lib/mcp/server/handler.ex`, `lib/mcp/server/notification_collector.ex`, `lib/mcp/server/state_handle.ex` | — | stable errors, concurrency, state ownership, delivery failures | merged PR diff |
| modified | `lib/mcp/transport/sse.ex`, `lib/mcp/transport/stdio/process.ex`, `lib/mcp/transport/streamable_http/client.ex`, `lib/mcp/transport/streamable_http/legacy_session_manager.ex`, `lib/mcp/transport/streamable_http/plug.ex` | — | bounded parsing, cleanup, expiry, and authorization | merged PR diff |
| created | `lib/mcp/transport/stdio/signal.ex` | — | bounded signal dispatch diagnostics | merged PR diff |
| created | `test/examples/quickstart_server_test.exs`, `test/mcp/protocol/open_type_audit_test.exs`, `test/mcp/transport/stdio_fixture_test.exs`, `test/mcp/transport/stdio_signal_test.exs`, `test/support/stdio_fixture.ex` | — | new executable and regression coverage | merged PR diff |
| modified | `test/mcp/client/subscription_worker_test.exs`, `test/mcp/client_lifecycle_test.exs`, `test/mcp/client_review_remediation_test.exs`, `test/mcp/client_test.exs`, `test/mcp/dual_protocol_compatibility_test.exs` | — | client regression coverage | merged PR diff |
| modified | `test/mcp/protocol/error_test.exs`, `test/mcp/protocol/messages/resources_directory_test.exs`, `test/mcp/protocol/messages/skills_test.exs` | — | protocol round-trip coverage | merged PR diff |
| modified | `test/mcp/server/config_test.exs`, `test/mcp/server/legacy_protocol_hardening_test.exs`, `test/mcp/server/notification_collector_test.exs`, `test/mcp/server/state_handle_test.exs`, `test/mcp/subscriptions_stdio_integration_test.exs` | — | server and subscription regression coverage | merged PR diff |
| modified | `test/mcp/transport/legacy_session_hardening_test.exs`, `test/mcp/transport/sse_test.exs`, `test/mcp/transport/stdio_security_test.exs`, `test/mcp/transport/stdio_test.exs`, `test/mcp/transport/streamable_http_stateless_test.exs` | — | transport regression coverage | merged PR diff |
| modified | `test/support/mock_transport.ex`, `test/support/stateless_handler.ex`, `test/support/subscription_handler.ex` | — | deterministic test support | merged PR diff |

## Beads Activity

No bead activity observed. `bd list --all --sort updated --reverse --limit 100 --json` returned no recorded session items.

## Repository Maintenance

- Plans: `find docs/plans -maxdepth 2 -type f` returned no plan files, so none were moved.
- Beads: no relevant tracker records were available; no state was created or changed.
- Worktrees: `git worktree list --porcelain` showed one clean worktree on `main`; no stale worktree existed.
- Branches: the merged topic ref was already absent from the remote when deletion was attempted, so cleanup was a no-op. Unrelated historical refs were left for the subsequent `repo-status` audit.
- Stale docs: installation-coordinate and Inspector-auth wording found during review were corrected before merge.

## Tools and Skills Used

- Shell and Git: repository inspection, focused/full verification, commit, push, PR, merge, ancestry, and worktree checks. One attempted topic-ref deletion found the ref already absent.
- GitHub CLI: PR creation/status, review comments, exact-head checks, merge verification, and CI watching.
- File editing: `apply_patch` for scoped Elixir, JavaScript, YAML, test, and documentation changes.
- Skills: `elixir-phoenix:phx-review`, `vibin:review-pr`, `vibin:save-to-md`, and `vibin:repo-status`.
- Review agents: runtime, protocol, transport, correctness, tests, silent-failure, type-design, comment, and simplification review lanes; final repeat review was clean.
- Browser tooling: the official MCP Inspector and Playwright ran through CI; no interactive browser tool was used locally.

## Commands Executed

| Command | Result |
|---|---|
| `mix precommit` | Final run passed with 607 tests plus Credo, Dialyzer, docs, package smoke, audits, and JSON checks |
| `actionlint .github/workflows/ci.yml .github/workflows/mcp-apps-browser-interop.yml` | Passed |
| `node --test conformance/apps_browser_report.test.mjs` | 2 tests passed |
| `gh pr checks 6 --watch` | All exact-head required jobs passed |
| `gh pr merge` / PR inspection | PR #6 merged as `3576cdaf` |
| `git merge-base --is-ancestor ecd3cb2f origin/main` | Confirmed reviewed head is contained in `main` |

## Errors Encountered

- Full-suite client waits timed out under load; bounded test waits were raised from one to five seconds and the complete suite passed.
- Stdio cleanup raced process disappearance and late TERM handlers; cleanup now separates graceful and forced budgets and verifies final absence.
- Dialyzer rejected an unreachable fallback clause added during remediation; the impossible clause was removed and Dialyzer passed.
- An upstream-repository PR was opened accidentally because `gh` selected the upstream repository; it was closed and the mergeable fork PR #6 remained canonical.
- The merged topic branch deletion returned “not a valid object” because the ref had already been removed; no data remained to delete.

## Behavior Changes (Before/After)

| Area | Before | After |
|---|---|---|
| SDK onboarding | Stale or non-executable guidance | Executable quickstart and immutable reviewed snapshot |
| Protocol types | Some unknown members and absent/null distinctions were lost | Lossless JSON-open boundaries with precise types |
| Legacy HTTP | Expiry and volatile request options could leave stale or rejected sessions | Deferred invalidation and explicit stable authorization context |
| Server concurrency | Duplicate in-flight request IDs and send failures were insufficiently guarded | Duplicate rejection and propagated delivery failures |
| Stdio cleanup | Racy generic failures and possible diagnostic loss | Forced cleanup confirmation with bounded diagnostics |
| Browser evidence | Success-shaped report even on later browser errors | Explicit pass/fail report with negative-path tests |

## Verification Evidence

| Command | Expected | Actual | Status |
|---|---|---|---|
| `mix precommit` | Complete project gate | 607 tests, 0 failures; all quality/package checks passed | pass |
| `node --test conformance/apps_browser_report.test.mjs` | Report pass/failure behavior | 2 passed | pass |
| `actionlint ...` | Valid CI workflows | No findings | pass |
| GitHub CI at `ecd3cb2f` | Matrix, quality, constrained, conformance, browser | All required jobs succeeded | pass |
| Final review rerun | No actionable findings | Code and test reviewers reported clean | pass |

## Risks and Rollback

- The merge changes public lifecycle and serialization behavior across the SDK. Roll back with a revert of merge commit `3576cdaf` if a release-blocking regression appears; avoid rewriting `main`.
- The documentation snapshot SHA intentionally identifies a reviewed commit rather than a release. Replace it with a tag or Hex coordinate during publication.

## Decisions Not Taken

- The cross-repository upstream PR was not retained because its base had diverged substantially and the fork PR was the intended, mergeable integration path.
- Signal delivery errors are ignored only when final process absence proves cleanup succeeded; genuine confirmation failures retain diagnostics.
- MCP Apps browser evidence remains a separate workflow instead of becoming a Hex runtime or package-CI dependency.

## References

- PR #6: https://github.com/jmagar/mcp-elixir-sdk/pull/6
- Merge commit: `3576cdaf8ce622de61c56ff614359ca92a97a0e5`
- Reviewed head: `ecd3cb2fd1b8b3533f34a52dab22f737c003850c`
- Exact-head CI: https://github.com/jmagar/mcp-elixir-sdk/actions/runs/32762873260
- Inspector browser evidence: https://github.com/jmagar/mcp-elixir-sdk/actions/runs/32762873251

## Next Steps

- Wait for the post-merge `main` CI run to complete before publication work.
- Replace the reviewed Git snapshot with a release tag or Hex coordinate when `2.0.0-rc.1` is published.
- Use the following repository-status audit to classify unrelated historical refs; do not remove them without ancestry and ownership proof.
