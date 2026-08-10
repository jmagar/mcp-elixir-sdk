# Tri-Version Secure Transports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support MCP `2025-06-18`, `2025-11-25`, and `2026-07-28` with version-isolated lifecycles, bounded HTTP and stdio transports, complete conformance evidence, Phoenix verification, and an immutable 2.0 release candidate coordinate.

**Architecture:** A protocol revision registry selects modern or revision-specific legacy adapters without scattering version conditionals. HTTP and stdio each receive a validated policy struct with secure defaults; the transport implementations consume only validated policies and return structured failures. Conformance ledgers and Phoenix integration prove the public claims before version metadata changes.

**Tech Stack:** Elixir 1.17+, OTP, Req 0.5 through 0.7, erlexec 2.3, Plug/Bandit, Jason, ExUnit, official `@modelcontextprotocol/conformance@0.2.0-alpha.11`, Mix/Hex.

## Global Constraints

- Supported revisions are exactly `2026-07-28`, `2025-11-25`, and `2025-06-18`, in that preference order.
- `2026-07-28` remains stateless; neither legacy revision may leak initialization/session behavior into it.
- Fallback occurs only for explicit unsupported-version or incompatible-lifecycle results.
- HTTP redirects and retries default to disabled; finite bodies and SSE frames are bounded before decoding.
- Stdio malformed or oversized stdout closes the upstream; stderr is never parsed as protocol data.
- Externally supplied version strings remain binaries; never call `String.to_atom/1` on them.
- Existing 2.0 startup calls remain source-compatible when they do not request unsafe behavior.
- Hex publication is not authorized by this plan.
- Do not move or reuse the existing `2.0.0-dev.2` tag.
- Use TDD and commit after every task passes its focused verification.

---

## File Structure

New production modules:

- `lib/mcp/protocol/revision.ex` — immutable revision metadata and selection API.
- `lib/mcp/protocol/legacy_adapter.ex` — behavior implemented by each legacy revision.
- `lib/mcp/protocol/legacy/v2025_06_18.ex` — 2025-06-18 lifecycle/wire rules.
- `lib/mcp/protocol/legacy/v2025_11_25.ex` — 2025-11-25 lifecycle/wire rules.
- `lib/mcp/transport/streamable_http/security_policy.ex` — validated HTTP policy.
- `lib/mcp/transport/streamable_http/response_reader.ex` — bounded Req async response consumption.
- `lib/mcp/transport/stdio/security_policy.ex` — validated subprocess/framing policy.
- `lib/mcp/transport/stdio/process.ex` — platform process adapter with a Unix erlexec backend.

Existing orchestration modules remain responsible for orchestration only:

- `MCP.Client` selects a revision and delegates revision-specific messages.
- `MCP.Server.LegacyDispatch` delegates legacy validation/projection.
- Streamable HTTP Client owns request/task/session state but delegates policy and body reading.
- Stdio owns MCP transport messages but delegates subprocess mechanics.

---

### Task 1: Protocol Revision Registry and Legacy Adapters

**Files:**
- Create: `lib/mcp/protocol/revision.ex`
- Create: `lib/mcp/protocol/legacy_adapter.ex`
- Create: `lib/mcp/protocol/legacy/v2025_06_18.ex`
- Create: `lib/mcp/protocol/legacy/v2025_11_25.ex`
- Modify: `lib/mcp/protocol.ex:9-29`
- Test: `test/mcp/protocol/revision_test.exs`
- Modify: `mix.exs:117-124`

**Interfaces:**
- Produces: `MCP.Protocol.Revision.supported/0 :: [String.t(), ...]`
- Produces: `MCP.Protocol.Revision.fetch/1 :: {:ok, :stateless | module()} | {:error, {:unsupported_protocol_version, String.t()}}`
- Produces: legacy adapter callbacks `version/0`, `initialize_params/2`, `validate_initialize_result/1`, `http_session?/0`, and `project_capabilities/1`.

- [ ] **Step 1: Write registry and adapter contract tests**

Create tests asserting:

```elixir
assert Revision.supported() == ["2026-07-28", "2025-11-25", "2025-06-18"]
assert {:ok, V2025_11_25} = Revision.fetch("2025-11-25")
assert {:ok, V2025_06_18} = Revision.fetch("2025-06-18")
assert {:error, {:unsupported_protocol_version, "bogus"}} = Revision.fetch("bogus")

for adapter <- [V2025_11_25, V2025_06_18] do
  params = adapter.initialize_params(%{name: "client", version: "1"}, %{})
  assert params["protocolVersion"] == adapter.version()
  assert adapter.http_session?()
end
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `mix test test/mcp/protocol/revision_test.exs --seed 0`  
Expected: compilation failure because `MCP.Protocol.Revision` does not exist.

- [ ] **Step 3: Implement the behavior, registry, and two explicit adapters**

Use binary-keyed compile-time maps:

```elixir
@adapters %{
  "2025-11-25" => MCP.Protocol.Legacy.V2025_11_25,
  "2025-06-18" => MCP.Protocol.Legacy.V2025_06_18
}
@supported ["2026-07-28", "2025-11-25", "2025-06-18"]
```

`MCP.Protocol.supported_versions/0` delegates to `Revision.supported/0`. Each adapter constructs and validates its own exact initialize version rather than accepting any legacy string.

- [ ] **Step 4: Run protocol tests**

Run: `mix test test/mcp/protocol/revision_test.exs test/mcp/protocol_test.exs test/mcp/protocol/messages/initialize_test.exs --seed 0`  
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/mcp/protocol.ex lib/mcp/protocol/revision.ex lib/mcp/protocol/legacy_adapter.ex lib/mcp/protocol/legacy test/mcp/protocol/revision_test.exs mix.exs
git commit -m "feat(protocol): add tri-version revision registry"
```

### Task 2: Tri-Version Client Negotiation and Server Dispatch

**Files:**
- Modify: `lib/mcp/client.ex:71-72,329-370,819-876,1030-1080,2309-2363`
- Modify: `lib/mcp/server/legacy_dispatch.ex:17-47,175-213`
- Modify: `lib/mcp/transport/streamable_http/plug.ex:450-610`
- Modify: `lib/mcp/transport/streamable_http/legacy_session.ex`
- Modify: `lib/mcp/transport/streamable_http/legacy_session_manager.ex`
- Test: `test/mcp/tri_version_compatibility_test.exs`
- Modify: `test/mcp/dual_protocol_compatibility_test.exs`
- Modify: `test/mcp/server/legacy_protocol_hardening_test.exs`

**Interfaces:**
- Consumes: `Revision.supported/0`, `Revision.fetch/1`, and legacy adapter callbacks from Task 1.
- Produces: client state fields `fallback_versions :: [String.t()]` and `legacy_adapter :: module() | nil`.
- Produces: server legacy session records containing the negotiated binary `protocol_version`.

- [ ] **Step 1: Write failing explicit and automatic negotiation tests**

Cover this sequence:

```elixir
assert Protocol.supported_versions() == [modern, november, june]
assert initialize_for_explicit(june)["params"]["protocolVersion"] == june
assert {:ok, %{protocol_version: june}} = connect_after_supported_versions([june])
assert attempts_after_supported_versions([november, june]) == [modern, november]
```

Also assert that 401/403, TLS/network errors, malformed JSON, overflow, and timeout do not consume another fallback version.

- [ ] **Step 2: Run focused tests and verify the June cases fail**

Run: `mix test test/mcp/tri_version_compatibility_test.exs test/mcp/dual_protocol_compatibility_test.exs --seed 0`  
Expected: June selection/fallback and server initialization fail.

- [ ] **Step 3: Replace the single legacy constant with adapter selection**

Initialize client state with:

```elixir
fallback_versions: tl(Revision.supported()),
legacy_adapter: nil
```

On explicit legacy configuration or supported-version fallback, call `Revision.fetch/1`, store the adapter, build initialization through it, and remove only the attempted version. Classify fallback errors with one function that accepts only unsupported-version/method-not-found lifecycle signals.

- [ ] **Step 4: Route legacy server initialization and sessions by exact revision**

`LegacyDispatch.initialize/2` fetches the requested adapter, validates with that adapter, stores its version in the session, and uses it for all later header/session checks. Reject a header/session version mismatch with `-32022`; do not silently switch adapters.

- [ ] **Step 5: Run client, legacy server, and HTTP session tests**

Run: `mix test test/mcp/tri_version_compatibility_test.exs test/mcp/dual_protocol_compatibility_test.exs test/mcp/client_review_remediation_test.exs test/mcp/server/legacy_protocol_hardening_test.exs test/mcp/transport/legacy_session_hardening_test.exs --seed 0`  
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/mcp/client.ex lib/mcp/server/legacy_dispatch.ex lib/mcp/transport/streamable_http/plug.ex lib/mcp/transport/streamable_http/legacy_session.ex lib/mcp/transport/streamable_http/legacy_session_manager.ex test/mcp
git commit -m "feat(protocol): negotiate all three MCP revisions"
```

### Task 3: Validated HTTP Security Policy

**Files:**
- Create: `lib/mcp/transport/streamable_http/security_policy.ex`
- Modify: `lib/mcp/transport/streamable_http/client.ex:46-61,109-145`
- Test: `test/mcp/transport/streamable_http_security_policy_test.exs`
- Modify: `mix.exs:125-132`

**Interfaces:**
- Produces: `SecurityPolicy.default/0` and `gateway/0`.
- Produces: `SecurityPolicy.new/1 :: {:ok, t()} | {:error, {:invalid_security_policy, term()}}`.
- Produces: `SecurityPolicy.validate_url/2 :: {:ok, URI.t()} | {:error, term()}`.
- Client state stores validated `endpoint :: URI.t()` and `security_policy :: SecurityPolicy.t()`.

- [ ] **Step 1: Write failing policy and URL tests**

Assert secure defaults and validation:

```elixir
assert policy.redirect == :reject
assert policy.retry == false
assert policy.max_response_bytes == 1_000_000
assert policy.max_sse_event_bytes == 1_000_000
assert {:error, _} = SecurityPolicy.validate_url(policy, "file:///tmp/mcp")
assert {:error, _} = SecurityPolicy.validate_url(policy, "https://user:pass@example/mcp")
assert {:error, _} = SecurityPolicy.validate_url(policy, "https://example/mcp#fragment")
assert {:ok, %URI{scheme: "http", host: "127.0.0.1"}} =
         SecurityPolicy.validate_url(policy, "http://127.0.0.1:4000/mcp")
```

Use defaults: connect 5 seconds, receive/idle 30 seconds, finite request 60 seconds, 1,000,000 response bytes, 1,000,000 SSE-event bytes, compression disabled.

- [ ] **Step 2: Run the focused test and verify failure**

Run: `mix test test/mcp/transport/streamable_http_security_policy_test.exs --seed 0`  
Expected: missing policy module.

- [ ] **Step 3: Implement validated policy constructors and URL normalization**

Use an explicit struct and reject non-positive limits/timeouts. Accept loopback HTTP only for `localhost`, `127.0.0.0/8`, and `::1`; require HTTPS elsewhere unless `allow_non_loopback_http: true` is explicitly validated.

- [ ] **Step 4: Integrate policy validation into Client.init/1**

Replace `Keyword.fetch!(opts, :url)` storage with controlled `{:stop, reason}` initialization errors. Preserve `:url` as the public option and store its normalized string for Req plus parsed endpoint for observability.

- [ ] **Step 5: Run policy and existing client tests**

Run: `mix test test/mcp/transport/streamable_http_security_policy_test.exs test/mcp/transport/streamable_http_client_test.exs --seed 0`  
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/mcp/transport/streamable_http/security_policy.ex lib/mcp/transport/streamable_http/client.ex test/mcp/transport/streamable_http_security_policy_test.exs mix.exs
git commit -m "feat(http): add validated transport security policy"
```

### Task 4: Bounded HTTP Response Reader and Redirect/Deadline Enforcement

**Files:**
- Create: `lib/mcp/transport/streamable_http/response_reader.ex`
- Modify: `lib/mcp/transport/sse.ex:117-130,190-204`
- Modify: `lib/mcp/transport/streamable_http/client.ex:374-470,680-695,744-930`
- Test: `test/mcp/transport/streamable_http_response_bounds_test.exs`
- Modify: `test/mcp/transport/sse_test.exs`

**Interfaces:**
- Consumes: validated `SecurityPolicy.t()` from Task 3.
- Produces: `ResponseReader.request/2 :: {:ok, Req.Response.t(), binary()} | {:stream, Req.Response.t()} | {:error, term()}`.
- Produces: `ResponseReader.consume/3` with byte counting and `Req.cancel_async_response/1` on overflow/deadline.
- Extends: `SSE.new_parser/1` accepts `max_event_bytes:` and returns `{:error, :event_too_large}` from bounded feeding.

- [ ] **Step 1: Write failing redirect, byte-limit, SSE-limit, and deadline tests**

Create local Bandit fixtures for 301/302/303/307/308, chunked oversized JSON, a never-terminated SSE event, compressed expansion, and slow-drip chunks. Assert the redirect target receives no request and no configured secret header.

- [ ] **Step 2: Run focused tests and verify current buffering/redirect behavior fails**

Run: `mix test test/mcp/transport/streamable_http_response_bounds_test.exs test/mcp/transport/sse_test.exs --seed 0`  
Expected: redirect is followed or bounds/deadline assertions fail.

- [ ] **Step 3: Implement one Req template for POST, GET, and DELETE**

Set:

```elixir
redirect: false,
retry: false,
raw: true,
compressed: false,
connect_options: [timeout: policy.connect_timeout],
receive_timeout: policy.receive_timeout,
request_timeout: policy.request_timeout,
into: :self
```

Treat every 3xx as `{:error, {:redirect_rejected, status, sanitized_location}}`.

- [ ] **Step 4: Implement incremental finite-body consumption**

Count each `{:data, chunk}` before adding it to iodata. Cancel and return `{:error, {:response_too_large, limit}}` as soon as the next chunk crosses the bound. Decode only after `:done` and successful size validation.

- [ ] **Step 5: Bound POST-SSE, legacy GET-SSE, and subscription SSE**

All three paths share the bounded SSE parser and idle-timeout receive loop. Preserve subscription acknowledgment/backpressure behavior and explicit cancellation.

- [ ] **Step 6: Run the complete HTTP transport test set**

Run: `mix test test/mcp/transport/streamable_http_response_bounds_test.exs test/mcp/transport/sse_test.exs test/mcp/transport/streamable_http_client_test.exs test/mcp/transport/streamable_http_recovery_test.exs test/mcp/subscriptions_http_integration_test.exs --seed 0`  
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add lib/mcp/transport/sse.ex lib/mcp/transport/streamable_http/client.ex lib/mcp/transport/streamable_http/response_reader.ex test/mcp/transport test/mcp/subscriptions_http_integration_test.exs
git commit -m "feat(http): bound and harden upstream responses"
```

### Task 5: Validated Stdio Policy and Process-Group Owner

**Files:**
- Modify: `mix.exs:140-154`
- Create: `lib/mcp/transport/stdio/security_policy.ex`
- Create: `lib/mcp/transport/stdio/process.ex`
- Modify: `lib/mcp/transport/stdio.ex`
- Create: `test/support/adversarial_stdio_server.exs`
- Test: `test/mcp/transport/stdio_security_test.exs`
- Modify: `test/mcp/transport/stdio_test.exs`

**Interfaces:**
- Produces: `MCP.Transport.Stdio.SecurityPolicy.default/0`, `gateway/0`, and `new/1`.
- Produces: `MCP.Transport.Stdio.Process.start_link/1`, `write/2`, and `close/2` wrapping a platform backend; Unix uses erlexec process groups.
- Stdio state stores `security_policy`, `process`, bounded `buffer`, and reader task.

- [ ] **Step 1: Add erlexec 2.3 and write failing policy tests**

Add `{:erlexec, "~> 2.3"}` and assert:

```elixir
assert policy.max_frame_bytes == 1_000_000
assert policy.malformed_output == :close
assert policy.stderr == :disable
assert policy.environment == :replace
assert {:error, _} = SecurityPolicy.new(max_frame_bytes: 0)
```

- [ ] **Step 2: Write adversarial subprocess tests**

The fixture accepts a mode argument and emits: a partial frame at limit, limit+1, malformed JSON, scalar JSON, stdout flood, stderr flood, graceful exit, ignored stdin/TERM, and a spawned descendant PID. Tests assert structured closure reasons and that the transport stays responsive under output pressure.

- [ ] **Step 3: Run focused tests and verify failure**

Run: `mix deps.get && mix test test/mcp/transport/stdio_security_test.exs --seed 0`  
Expected: missing policy/process modules and current malformed-output behavior fails.

- [ ] **Step 4: Implement policy and Unix process-group owner**

Launch the configured executable directly through erlexec with explicit argv, `{env, [clear | entries]}`, `stdin`, independently tagged `stdout` and `stderr`, `monitor`, `kill_group`, and `kill_timeout`. The adapter forwards bounded chunks to Stdio, keeps stderr on a separate diagnostic path, and maps exit/timeout results to stable SDK closure reasons.

Accept `:capture`, `:console`, and `:disable` stderr policies. `:capture` applies the diagnostic byte/rate bounds before delivering redacted diagnostics; `:console` is explicit inheritance behavior; `:disable` discards stderr without ever joining it to stdout. Reject any option that redirects stderr into stdout because it corrupts the protocol channel.

- [ ] **Step 5: Implement bounded iterative framing and JSON-RPC validation**

Reject before append when `byte_size(buffer) + byte_size(chunk)` exceeds the incomplete-frame limit and no newline releases a valid frame. Decode only JSON objects and pass the map through `MCP.Protocol.decode_message/1`; close on any parse/classification error. Schedule remaining complete frames back to the GenServer after a bounded per-turn count.

- [ ] **Step 6: Implement explicit environment and shutdown behavior**

`gateway/0` uses replacement environment only. To preserve existing SDK startup calls, `default/0` inherits the environment; hardened consumers opt into `gateway/0` or explicit `environment: :replace`. Close stops writes, closes stdin, requests termination, waits for the configured 5-second deadline, then kills and confirms the entire process group. Report a surviving group as `{:error, :process_group_cleanup_failed}` rather than returning success.

- [ ] **Step 7: Run all stdio tests**

Run: `mix test test/mcp/transport/stdio_security_test.exs test/mcp/transport/stdio_test.exs test/mcp/integration_test.exs test/mcp/subscriptions_stdio_integration_test.exs --seed 0`  
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add mix.exs mix.lock lib/mcp/transport/stdio.ex lib/mcp/transport/stdio test/support/adversarial_stdio_server.exs test/mcp/transport/stdio_security_test.exs test/mcp/transport/stdio_test.exs
git commit -m "feat(stdio): enforce bounded secure subprocess policies"
```

### Task 6: Three-Version Conformance Adapters and Evidence

**Files:**
- Modify: `conformance/client_adapter.exs`
- Modify: `conformance/server_adapter.exs`
- Create: `conformance/compatibility-2025-06-18.json`
- Modify: `conformance/compatibility-2025-11-25.json`
- Modify: `conformance/scenarios.json`
- Modify: `conformance/README.md`
- Modify: `docs/dev-tooling.md`
- Modify: `mix.exs:163-175`

**Interfaces:**
- Adapters consume `MCP_CONFORMANCE_PROTOCOL_VERSION` with exact registry validation.
- Ledgers expose `harness`, `protocolVersion`, `verifiedOn`, exact commands, scenario IDs, exclusions, and pass/fail/warning totals.

- [ ] **Step 1: Enumerate exact official denominators**

Run:

```bash
# The pinned harness has no official 2025-06-18 requirements profile; record that absence.
npx --no-install conformance list --client --requirements 2025-11-25
npx --no-install conformance list --server --requirements 2025-11-25
npx --no-install conformance list --client --requirements 2026-07-28
npx --no-install conformance list --server --requirements 2026-07-28
```

Record the exact output before editing ledgers.

- [ ] **Step 2: Extend adapters for exact revision selection**

Reject unknown environment values. Ensure the client adapter runs initialize/tools/SSE behavior for both legacy adapters and modern scenarios without lifecycle crossover.

- [ ] **Step 3: Run every applicable server requirement set**

Run official server profiles where the pinned harness exposes them. For 2025-06-18, record the absent official denominator and run the SDK-owned lifecycle/transport matrix.

- [ ] **Step 4: Run every applicable non-authorization client scenario**

Invoke `conformance client --command 'mix run conformance/client_adapter.exs' --scenario NAME --spec-version REVISION` for every listed scenario. Authorization remains excluded only where authentication is owned by the embedding transport pipeline; record that rationale per scenario family.

- [ ] **Step 5: Update ledgers and validation gates**

Add `jq empty conformance/compatibility-2025-06-18.json` to precommit. Replace the legacy one-scenario claim with exact scenario totals and IDs. Keep SDK integration coverage in a separately named field.

- [ ] **Step 6: Validate evidence files and rerun adapter smoke tests**

Run:

```bash
jq empty conformance/scenarios.json conformance/compatibility-2025-11-25.json conformance/compatibility-2025-06-18.json
mix run conformance/client_adapter.exs </dev/null
```

Expected: JSON validates; adapter exits only according to its documented stdin contract, with no compile error.

- [ ] **Step 7: Commit**

```bash
git add conformance docs/dev-tooling.md mix.exs
git commit -m "test(conformance): prove all supported MCP revisions"
```

### Task 7: Documentation, Types, and Package Surface

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/architecture.md`
- Modify: `docs/onboarding.md`
- Modify: `docs/sdk-2.0/specifications.md`
- Modify: `docs/sdk-2.0/contracts.md`
- Modify: `docs/sdk-2.0/types.md`
- Modify: `docs/sdk-2.0/runtime-models.md`
- Create: `docs/adr/0008-tri-version-secure-transports.md`
- Modify: `docs/adr/README.md`
- Modify: `mix.exs`

**Interfaces:**
- Public docs describe `SecurityPolicy.default/0`, `gateway/0`, `new/1`, exact error tags, version preference, and unsafe-fallback exclusions.

- [ ] **Step 1: Write doctest/public-surface assertions where executable**

Add tests or doctests verifying the README examples compile with all three explicit versions and both policy constructors.

- [ ] **Step 2: Update architecture, contracts, types, and ADR**

Replace every two-version union with:

```elixir
@type protocol_version :: "2026-07-28" | "2025-11-25" | "2025-06-18"
```

Document transport limits, failure tags, environment/stderr behavior, and why the three revisions remain isolated.

- [ ] **Step 3: Update README without claiming an unreleased coordinate**

Describe the current branch as unreleased and remove the stale `3fa6dce` installation pin. Use a conspicuous placeholder-free statement: consumers must use the release coordinate produced by Task 9; until then, no production installation coordinate is advertised.

- [ ] **Step 4: Generate docs and inspect warnings**

Run: `mix docs`  
Expected: success without undefined references for new policy/revision modules.

- [ ] **Step 5: Commit**

```bash
git add README.md CHANGELOG.md docs mix.exs test
git commit -m "docs: document tri-version secure transport contracts"
```

### Task 8: Phoenix and Actual-Unraid Integration Verification

**Files:**
- Create in Phoenix: `test/unraid/mcp/sdk_transport_integration_test.exs`
- Modify in Phoenix: `mix.exs`
- Modify in Phoenix: `mix.lock`
- Create in SDK: `test/runtime/unraid_stdio_cleanup.exs`
- Modify in SDK: `docs/dev-tooling.md`

**Interfaces:**
- Phoenix pins the exact SDK Git commit generated after Task 7, not a mutable branch.
- Phoenix constructs both transports with their `gateway/0` policies.

- [ ] **Step 1: Create and verify a separate isolated Phoenix worktree**

Inspect Phoenix worktrees and create a `codex/mcp-elixir-sdk-integration` worktree from
current `main` using the same worktree-isolation rules as the SDK. Run Phoenix's full
baseline test command before editing; stop and report if the baseline is not green.

- [ ] **Step 2: Record Phoenix baseline and add the exact SDK dependency**

In the isolated Phoenix worktree, add the SDK dependency using the current implementation commit SHA, run `mix deps.get`, and record the resolved Req version from `mix.lock` and `mix deps.tree`.

- [ ] **Step 3: Compile Phoenix and run focused integration tests**

Run:

```bash
mix compile --warnings-as-errors
mix test test/unraid/mcp/sdk_transport_integration_test.exs --seed 0
```

Cover one bounded HTTP tool call, one stdio tool call, one rejected redirect, and one malformed stdio disconnect.

- [ ] **Step 4: Run the complete Phoenix suite**

Run: `mix test --seed 0`  
Expected: all pass with the newly resolved Req lock.

- [ ] **Step 5: Run the actual-Unraid descendant cleanup probe**

Use the approved Labby/device route to the Unraid host. Confirm `hostname`, `whoami`, kernel, SDK artifact path, and test fixture path. Launch a fixture that spawns a descendant, close the SDK transport, and verify both direct child and descendant PIDs no longer exist. Record exact commands and outcomes in `docs/dev-tooling.md`.

- [ ] **Step 6: Commit Phoenix integration separately**

```bash
git add mix.exs mix.lock test/unraid/mcp/sdk_transport_integration_test.exs
git commit -m "test(mcp): verify secure Elixir SDK transports"
```

- [ ] **Step 7: Commit SDK runtime evidence**

```bash
git add test/runtime/unraid_stdio_cleanup.exs docs/dev-tooling.md
git commit -m "test(stdio): record Unraid process cleanup verification"
```

### Task 9: Full SDK Gate and Immutable Release Candidate Coordinate

**Files:**
- Modify: `mix.exs:4-5,43-48,134-135`
- Modify: `README.md:30-45`
- Modify: `CHANGELOG.md`
- Modify: conformance ledgers' final `verifiedOn`/commit fields

**Interfaces:**
- Package version becomes a new unused prerelease, initially `2.0.0-rc.1` unless Hex/tag inspection shows that coordinate already exists.
- Canonical source URL and tag use one consistent repository and `v2.0.0-rc.1` convention.

- [ ] **Step 1: Run the canonical precommit gate before versioning**

Run: `mix precommit`  
Expected: format, warnings-as-errors compile, all tests, Credo, Dialyzer, docs, Hex build/audit, unused dependency check, diff check, and all conformance ledger JSON checks pass.

- [ ] **Step 2: Confirm the proposed coordinate is unused**

Run:

```bash
git ls-remote --tags origin 'refs/tags/v2.0.0-rc.1'
mix hex.info mcp_elixir_sdk
```

Expected: no existing Git tag or Hex 2.0 release uses `2.0.0-rc.1`. If occupied, increment only the RC number and use that exact value consistently below.

- [ ] **Step 3: Align version and provenance metadata**

Set `@version`, canonical source URL, package links, ExDoc `source_ref`, changelog heading, and README install example to the exact unused RC coordinate. README uses either Hex `{:mcp_elixir_sdk, "~> 2.0.0-rc.1"}` after publication or the exact Git commit/tag for the unpublished candidate; do not claim Hex availability before publication.

- [ ] **Step 4: Build and inspect the package archive**

Run:

```bash
mix hex.build
tar -tf mcp_elixir_sdk-2.0.0-rc.1.tar | sort
```

Expected: archive contains `lib`, complete required `docs`, conformance ledgers, README, changelog, license, and no `_build`, `deps`, session logs, or secrets.

- [ ] **Step 5: Rerun the full gate at the release commit**

Run: `mix precommit`  
Expected: all pass.

- [ ] **Step 6: Commit the release candidate metadata**

```bash
git add mix.exs README.md CHANGELOG.md conformance
git commit -m "chore(release): prepare v2.0.0-rc.1"
```

- [ ] **Step 7: Verify Phoenix resolves the final release commit**

Update the Phoenix exact Git ref to the release commit, run `mix deps.get`, `mix compile --warnings-as-errors`, the focused SDK integration test, and the full Phoenix suite. Commit only the final ref change if it differs from Task 8.

- [ ] **Step 8: Stop before tagging or publishing**

Report the exact release commit, package archive, SDK gate, Phoenix gate, conformance totals, and Unraid cleanup evidence. Tag creation, push, PR/merge, and Hex publication require the branch-finishing workflow and explicit user selection.

---

## Final Verification Checklist

- [ ] `git status --short` is clean in SDK and Phoenix worktrees.
- [ ] `mix precommit` passes from the SDK release commit.
- [ ] Every available official server profile passes; the absent June denominator and SDK-owned June evidence are recorded.
- [ ] Every applicable official client scenario is recorded or explicitly excluded.
- [ ] Phoenix compiles and its full suite passes with the exact SDK ref and resolved Req lock.
- [ ] HTTP redirect, size, SSE, and deadline adversarial tests pass.
- [ ] Stdio frame, malformed output, stderr policy, shutdown, and descendant tests pass.
- [ ] Actual Unraid child and descendant cleanup is directly verified.
- [ ] Package archive contents and version/provenance metadata agree.
- [ ] No tag was moved or created and nothing was published to Hex.
