---
date: 2026-08-24 13:14:07 EDT
repo: git@github.com:jmagar/mcp-elixir-sdk.git
branch: codex/mcp-apps
head: 56d24bf5796420de1fa24fa3efa262a2c039dbee
session id: 01a03241-7157-78d1-a9f7-ef0da13c54c4
transcript: /home/jmagar/.codex/sessions/2026/08/24/rollout-2026-08-24T01-32-24-01a03241-7157-78d1-a9f7-ef0da13c54c4.jsonl
working directory: /home/jmagar/workspace/mcp-elixir-sdk/.worktrees/codex/mcp-apps
worktree: /home/jmagar/workspace/mcp-elixir-sdk/.worktrees/codex/mcp-apps
pr: "#5 feat: add stable MCP Apps support (https://github.com/jmagar/mcp-elixir-sdk/pull/5)"
beads: mcp-elixir-sdk-ehg, mcp-elixir-sdk-ehg.1, mcp-elixir-sdk-ehg.2, mcp-elixir-sdk-ehg.3, mcp-elixir-sdk-ehg.4
---

# Stable MCP Apps support

## User Request

Create a new worktree, thoroughly research MCP Apps and the current codebase, produce and engineering-review a detailed Lavra plan in Beads, implement the complete epic, open and review a PR, address every finding, push, and merge after PR #4.

## Session Overview

Implemented stable MCP Apps 2026-01-26 support at the Elixir SDK boundary, including validation, immutable authoring definitions, capability-aware client resolution, bridge codecs and lifecycle checks, open-object metadata preservation, documentation, and conformance evidence. The work was reviewed repeatedly, remediated, rebased by merging the newly landed Skills work from PR #4, verified on the exact integration head, and merged as PR #5.

## Sequence of Events

1. Created the isolated `codex/mcp-apps` worktree and inspected repository architecture, protocol-era boundaries, transports, metadata codecs, tests, and prior decisions.
2. Researched stable SEP-1865 and the official ext-apps sources, distinguishing stable `2026-01-26` from development drafts and obsolete pre-SEP formats.
3. Created the `mcp-elixir-sdk-ehg` epic and four detailed child beads, then incorporated architecture, simplicity, performance, security, and prior-learning review findings.
4. Implemented the Apps modules, resource open-object preservation, tests, evidence ledger, ADR, package/docs integration, and dependency security upgrades.
5. Ran engineering and PR reviews, fixed bridge validation, negotiation, catalog ownership, URI compatibility, lifecycle ordering, metadata handling, and Dialyzer/CI findings.
6. Applied the explicit Phoenix review, fixed all four surfaced defect roots, pushed commit `295e6543`, and obtained green exact-head CI.
7. Waited for PR #4, integrated merge commit `2275b68d`, resolved the README overlap, verified Apps and Skills together, pushed `56d24bf5`, and merged PR #5 to `main` as `b2545e07`.

## Key Findings

- Stable MCP Apps uses extension `io.modelcontextprotocol/ui`, MIME `text/html;profile=mcp-app`, canonical `_meta.ui.resourceUri`, and `ui/initialize` followed by `ui/notifications/initialized`; older `text/html+mcp` and `iframe-ready` conventions were excluded.
- A remote MCP server cannot infer browser/model origin from ordinary JSON-RPC. App visibility and same-server enforcement therefore belong to the Apps-aware host bound to the exact `MCP.Client`, not forgeable wire metadata.
- UI resolution can read the exact linked `ui://` URI directly and must not scan all resources, prefetch, retry, or add an SDK cache.
- Resource-family structs previously lost unknown top-level members; `MCP.Protocol.OpenObject` now preserves forward-compatible string-key JSON members while rejecting collisions.
- Browser iframe execution remains an external host-runtime proof boundary; the SDK models and validates the protocol but does not claim to render Apps.

## Technical Decisions

- Targeted only stable SEP-1865 and treated development-draft features as deferred.
- Kept Apps as a thin layer over existing tools/resources and transports; no mutable registry, renderer, transport-specific parser, or Apps cache was introduced.
- Used a pure bounded bridge codec/lifecycle transition model rather than an SDK-owned GenServer or browser adapter runtime.
- Required helper-owned catalogs for sibling-tool authorization and exact-client bindings for host-side calls.
- Applied one-megabyte-aligned resource/message defaults plus depth/node limits at Apps boundaries, including base64 prechecks.

## Files Changed

| status | path | previous path | purpose | evidence |
|---|---|---|---|---|
| modified | `.github/workflows/ci.yml` | — | Validate the Apps conformance ledger in CI | `1349fd74..295e6543` |
| modified | `CHANGELOG.md` | — | Document stable Apps support | `1349fd74..295e6543` |
| modified | `README.md` | — | Add Apps capabilities and usage guidance | `1349fd74..295e6543` |
| modified | `conformance/README.md` | — | Separate Apps evidence from core conformance | `1349fd74..295e6543` |
| created | `conformance/mcp-apps-2026-01-26.json` | — | Record stable Apps evidence and external boundaries | `1349fd74..295e6543` |
| created | `docs/adr/0009-mcp-apps-support.md` | — | Capture scope and trust-boundary decisions | `1349fd74..295e6543` |
| modified | `docs/prd.md` | — | Align product scope with implemented Apps support | `1349fd74..295e6543` |
| modified | `docs/sdk-2.0/specifications.md` | — | Document stable extension status and evidence | `1349fd74..295e6543` |
| created | `lib/mcp/apps.ex` | — | Public constants and capability helpers | `1349fd74..295e6543` |
| created | `lib/mcp/apps/app_definition.ex` | — | Immutable linked tool/resource catalogs | `1349fd74..295e6543` |
| created | `lib/mcp/apps/bridge.ex` | — | Stable bounded bridge codec and lifecycle validation | `1349fd74..295e6543` |
| created | `lib/mcp/apps/client.ex` | — | Capability-gated exact-resource resolution and calls | `1349fd74..295e6543` |
| created | `lib/mcp/apps/limits.ex` | — | Apps validation limits | `1349fd74..295e6543` |
| created | `lib/mcp/apps/resolved_app.ex` | — | Validated resolved-App representation and binding | `1349fd74..295e6543` |
| created | `lib/mcp/apps/validator.ex` | — | URI, MIME, metadata, CSP, permission, and content validation | `1349fd74..295e6543` |
| modified | `lib/mcp/client.ex` | — | Expose server capabilities needed for negotiation checks | `1349fd74..295e6543` |
| created | `lib/mcp/protocol/open_object.ex` | — | Shared unknown-member codec support | `1349fd74..295e6543` |
| modified | `lib/mcp/protocol/types/content/resource_link.ex` | — | Preserve open members | `1349fd74..295e6543` |
| modified | `lib/mcp/protocol/types/resource.ex` | — | Preserve open members | `1349fd74..295e6543` |
| modified | `lib/mcp/protocol/types/resource_contents.ex` | — | Preserve open members | `1349fd74..295e6543` |
| modified | `lib/mcp/protocol/types/resource_template.ex` | — | Preserve open members | `1349fd74..295e6543` |
| modified | `mix.exs` | — | Package and documentation integration | `1349fd74..295e6543` |
| modified | `mix.lock` | — | Upgrade Bandit and resolved dependencies past advisories | `1349fd74..295e6543` |
| created | `test/mcp/apps_test.exs` | — | Apps validation, client, catalog, and bridge regressions | `1349fd74..295e6543` |

## Beads Activity

| bead | title | actions | final status | why it mattered |
|---|---|---|---|---|
| `mcp-elixir-sdk-ehg` | Add full stable MCP Apps support | created, expanded with review decisions, claimed, commented, closed | closed | Defined the complete SDK-boundary epic and external proof boundary. |
| `mcp-elixir-sdk-ehg.1` | Model and validate stable MCP Apps protocol | created, detailed, implemented, closed | closed | Covered protocol values, metadata, limits, bridge shapes, and open objects. |
| `mcp-elixir-sdk-ehg.2` | Add immutable MCP Apps server authoring and authorization | created, trust boundary corrected, implemented, closed | closed | Prevented false remote-origin claims and defined helper-owned catalogs. |
| `mcp-elixir-sdk-ehg.3` | Add MCP Apps client resolution and host bridge support | created, simplified after review, implemented, closed | closed | Added exact-client, one-read resolution and pure lifecycle support. |
| `mcp-elixir-sdk-ehg.4` | Add Apps conformance, examples, documentation, and release evidence | created, commented, implemented, closed | closed | Kept Apps and core conformance claims separate and truthful. |

`bd lint` reported no template warnings for the relevant tracker state during closeout.

## Repository Maintenance

### Plans

- `find docs/plans -maxdepth 2 -type f` found no plan files, so no completed plans were moved.

### Beads

- Read the epic and all four child records before maintenance. They were already closed with implementation and verification evidence, so no status mutation or follow-up bead was warranted.

### Worktrees and branches

- `git worktree list --porcelain` showed the primary `main` checkout and the clean `codex/mcp-apps` worktree.
- The primary checkout contained numerous unrelated modified and untracked files; it was preserved untouched.
- GitHub proved PR #5 merged at `b2545e07`, and exact-head CI proved `56d24bf5` green. The feature worktree/branch was left in place during documentation publication so cleanup could not interfere with the active save operation.
- A temporary `session-log/2026-08-24-mcp-apps` worktree was created from fresh `origin/main` so only this artifact could land without touching unrelated dirt.

### Stale docs

- The implementation session updated README, changelog, PRD, SDK specifications, conformance docs, and ADR-0009. No additional contradicted document was identified during this focused maintenance pass.

## Tools and Skills Used

- **Shell and Git.** Inspected worktrees, branches, diffs, ancestry, dependencies, tests, CI, and merge state; created commits and pushed branches. The dirty primary checkout required an isolated worktree.
- **GitHub CLI.** Created and inspected PR #5, watched exact-head checks, verified PR #4, and merged PR #5. Duplicate push/PR workflow triggers both passed.
- **Web research.** Consulted official MCP/ext-apps sources for stable-versus-draft protocol behavior.
- **Beads CLI and Beads workflow.** Created and maintained the epic ledger and detailed child acceptance criteria.
- **Lavra skills and review agents.** Performed research, planning, architecture, simplicity, performance, implementation, and engineering-review passes; their findings materially narrowed trust boundaries and runtime scope.
- **Phoenix review/watch skills.** Performed a requirements-aware Elixir review, remediated all findings, then monitored integration CI before merge.
- **Vibin review/save skills.** Ran the PR review workflow and generated this session artifact.

## Commands Executed

| command | result |
|---|---|
| `git worktree add ... codex/mcp-apps` | Created the isolated implementation checkout. |
| `bd create`, `bd update`, `bd close`, `bd lint` | Managed the epic and four children; final lint clean. |
| `mix format --check-formatted` | Passed on reviewed and integration heads. |
| `mix compile --warnings-as-errors` | Passed. |
| `mix test test/mcp/apps_test.exs` | 10 tests passed after Phoenix review remediation. |
| `mix test` / `mix test --max-cases 1` | Feature head passed 519 tests before PR #4 integration; integration local aggregate runs exposed timing-sensitive pre-existing failures. |
| `mix test test/mcp/transport/stdio_security_test.exs --max-cases 1` | 19 tests passed in isolation. |
| `mix test test/mcp/apps_test.exs test/mcp/client_skills_test.exs test/mcp/protocol/messages/skills_test.exs test/mcp/server/skills_dispatch_test.exs --max-cases 1` | 39 integration-boundary tests passed. |
| `mix credo --strict` | Passed with no issues. |
| `mix hex.audit` | Passed after Bandit upgrades. |
| `gh pr checks 5 --watch --fail-fast` | All exact-head matrix, conformance, and quality checks passed. |
| `gh pr merge 5 --merge` | Merged PR #5 as `b2545e07`. |

## Errors Encountered

- The initial implementation was blocked by Bandit advisories. Bandit was upgraded to 1.12.5 and `mix hex.audit` passed.
- PR reviews found bridge payload validation gaps, missing capability intersection, unreachable listing metadata fallback, lifecycle ordering problems, catalog-policy bypasses, and malformed optional metadata handling. Each confirmed defect was fixed with regression tests.
- PR #5 became conflicting after PR #4 merged. `2275b68d` was merged into the feature branch; the only textual conflict was README capability bullets, and both Apps and Skills entries were retained.
- Two post-integration local aggregate test runs produced unrelated timing/process-cleanup failures, while the isolated stdio suite passed 19/19 and focused Apps/Skills tests passed 39/39. Both hosted exact-head CI triggers subsequently passed every matrix, conformance, and quality job.
- A local ancestry check initially failed because the newly created GitHub merge commit had not been fetched. An explicit `origin/main` fetch supplied the authoritative merge state.

## Behavior Changes (Before/After)

| area | before | after |
|---|---|---|
| Extension support | Generic metadata pass-through only | Stable MCP Apps constants, negotiation, validation, resolution, and bridge support |
| App authoring | Manual duplicated tool/resource maps | Immutable validated linked definitions and catalogs |
| Host resolution | Manual resource discovery and map parsing | Exact `ui://` one-read resolution with capability and content validation |
| App tool authorization | No SDK Apps-aware boundary | Helper-owned visibility plus exact-client host binding |
| Resource extensibility | Several resource types dropped unknown fields | Unknown string-key JSON members round-trip losslessly |
| Evidence | No Apps-specific ledger | Stable Apps evidence separated from core conformance and browser proof |

## Verification Evidence

| command | expected | actual | status |
|---|---|---|---|
| `mix compile --warnings-as-errors` | no compiler warnings | completed successfully | pass |
| Apps-focused tests | all Apps regressions pass | 10 tests, 0 failures | pass |
| Apps plus Skills integration tests | both merged features coexist | 39 tests, 0 failures | pass |
| Isolated stdio security tests | distinguish aggregate flake from regression | 19 tests, 0 failures | pass |
| `mix credo --strict` | no static-analysis issues | no issues | pass |
| `mix hex.audit` | no retired/vulnerable dependencies | no advisories | pass |
| GitHub exact-head CI | all required jobs green on `56d24bf5` | six test jobs, two conformance jobs, and two quality jobs passed | pass |
| PR merge verification | PR merged and `main` updated | PR #5 merged as `b2545e07` | pass |

## Risks and Rollback

- The Apps API is intentionally stable-spec-only; consumers needing development-draft features must not infer support from generic unknown fields.
- Browser rendering and postMessage execution remain embedding-host responsibilities and were not locally browser-verified.
- Rollback is a revert of merge commit `b2545e07`; dependency lockfile and Apps code/docs should be reverted together to preserve tested package state.

## Decisions Not Taken

- Did not implement obsolete `text/html+mcp`, `iframe-ready`, or current development-draft features.
- Did not add a browser renderer, mutable Apps registry, SDK cache, resource scan, transport hot-path Apps parsing, or process-per-message host runtime.
- Did not trust `_meta`, arguments, headers, or transport connection identity as proof of browser origin.
- Did not clean the dirty primary checkout or delete the feature worktree during active documentation publication.

## References

- [PR #5: stable MCP Apps support](https://github.com/jmagar/mcp-elixir-sdk/pull/5)
- [Stable MCP Apps specification](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx)
- [MCP Apps architecture overview](https://modelcontextprotocol.io/extensions/apps/overview)
- `docs/adr/0009-mcp-apps-support.md`
- `conformance/mcp-apps-2026-01-26.json`

## Open Questions

- Real browser/basic-host hydration remains an explicitly external verification boundary.
- The aggregate local suite showed timing-sensitive failures after combining branches despite isolated and hosted success; no integration regression was demonstrated, but future test-hardening may improve local determinism.

## Next Steps

- Consume `main` at merge commit `b2545e07` for stable MCP Apps SDK support.
- Run the documented external browser/basic-host recipe in an embedding host when end-to-end iframe hydration evidence is required.
- Remove the merged `codex/mcp-apps` worktree and branch later only after confirming no user process still depends on that path; the primary dirty checkout must remain untouched.
