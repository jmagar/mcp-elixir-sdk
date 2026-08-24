# MCP conformance adapters

These adapters target MCP `2026-07-28` and `2025-11-25` with the pinned harness
`@modelcontextprotocol/conformance@0.2.0-alpha.11`.

MCP Apps evidence is tracked separately in
`mcp-apps-2026-01-26.json`. The core harness does not currently prove browser
hydration, CSP, View/host lifecycle, or same-server App callback routing. Local
SDK tests prove the wire types, validation, exact resource read, binding, and
pure bridge contract. The separately triggered `MCP Apps browser
interoperability` workflow uses a fresh, token-authenticated official Inspector
host and uploads its policy probe, host version, screenshots, console/network
events, and server-side `resources/read`/same-server callback evidence. It is
deliberately not a dependency of package CI.

- `server_adapter.exs` exposes the SDK server over Streamable HTTP and includes
  harness-only diagnostic tools.
- `client_adapter.exs` drives the SDK client from the scenario and context
  environment variables supplied by the harness.
- `scenarios.json` is the 2026 machine-readable release ledger.
- `compatibility-2025-11-25.json` records the November server denominator and
  the exact client scenarios, exclusions, warnings, and remaining blocker.
- `apps_browser_adapter.exs` and `apps_browser_interop.mjs` are fixtures for the
  optional real-host workflow, not Hex package runtime code.
Use the exact commands in `docs/dev-tooling.md`. Harness-only diagnostic tools
are test fixtures, not public SDK behavior.
