# MCP conformance adapters

These adapters target MCP `2026-07-28` and `2025-11-25` with the pinned harness
`@modelcontextprotocol/conformance@0.2.0-alpha.11`.

MCP Apps evidence is tracked separately in
`mcp-apps-2026-01-26.json`. The core harness does not currently prove browser
hydration, CSP, View/host lifecycle, or same-server App callback routing. Local
SDK tests prove the wire types, validation, exact resource read, binding, and
pure bridge contract. The separate `MCP Apps browser interoperability` workflow
runs on pull requests and can also be dispatched manually. It uses a fresh
official Inspector host whose control API is token-authenticated; the fixture
MCP server is unauthenticated. It uploads
the policy probe, host version, screenshots, console/network
events, and server-side `resources/read`/same-server callback evidence. It is
deliberately not a dependency of package CI.

- `server_adapter.exs` exposes the SDK server over Streamable HTTP and includes
  harness-only diagnostic tools.
- `client_adapter.exs` drives the SDK client from the scenario and context
  environment variables supplied by the harness.
- `scenarios.json` is the historical 2026 qualification ledger. Current CI
  release evidence is generated from the executing commit and archived with
  checksums as `release-evidence.json` plus `SHA256SUMS`.
- `compatibility-2025-11-25.json` records the November server denominator and
  the exact client scenarios, exclusions, and warnings. The `initialize`
  scenario is excluded because this pinned harness returns an invalid JSON-RPC
  response to the client's required initialized notification. The `sse-retry` client
  scenario is recorded as partial and remains a release blocker because harness
  `0.2.0-alpha.11` negotiates unsupported revision `2025-03-26`; it is not
  represented as a passing check.
- `apps_browser_adapter.exs` and `apps_browser_interop.mjs` are fixtures for the
  separate real-host workflow, not Hex package runtime code.
Use the exact commands in `docs/dev-tooling.md`. Harness-only diagnostic tools
are test fixtures, not public SDK behavior.

CI validates both ledgers with `scripts/validate_conformance_ledgers.exs`, runs
every conformance command under a finite timeout, and uploads the server log and
per-scenario output as the `mcp-core-conformance` artifact even after failure.
The artifact is retained for 14 days.
