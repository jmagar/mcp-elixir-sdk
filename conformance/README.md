# MCP conformance adapters

These adapters target MCP `2026-07-28` and `2025-11-25` with the pinned harness
`@modelcontextprotocol/conformance@0.2.0-alpha.11`.

- `server_adapter.exs` exposes the SDK server over Streamable HTTP and includes
  harness-only diagnostic tools.
- `client_adapter.exs` drives the SDK client from the scenario and context
  environment variables supplied by the harness.
- `scenarios.json` is the 2026 machine-readable release ledger.
- `compatibility-2025-11-25.json` records the 2025 server denominator and the
  separately measured client compatibility evidence.

Use the exact commands in `docs/dev-tooling.md`. Harness-only diagnostic tools
are test fixtures, not public SDK behavior.
