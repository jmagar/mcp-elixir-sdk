# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0-dev.2] - Unreleased

### Added

- Core `2025-11-25` compatibility alongside `2026-07-28`: bounded client
  negotiation fallback, initialize/initialized, legacy Streamable HTTP
  sessions, GET SSE server requests, session DELETE, resource subscriptions,
  logging, roots, sampling, elicitation, ping, and legacy notifications.
- Stateless MCP `2026-07-28` client/server core with per-request metadata and
  `server/discover`.
- OTP-supervised stdio and Streamable HTTP subscriptions with explicit handles,
  acknowledgment-first ordering, filters, bounded queues, and cancellation.
- MRTR input-required client resolution, extension capability negotiation,
  lossless JSON Schema 2020-12, complete JSON structured-content values, W3C
  trace metadata, and schema-directed routing headers.
- Pinned official conformance adapters, scenario ledger, and CI release gates.
  The official 2025 server requirements denominator is covered; client
  compatibility evidence currently combines the official initialize scenario
  with the local cross-transport matrix rather than claiming a full official
  client denominator.

### Changed

- Streamable HTTP selects a protocol mode per request/session: stateless 2026
  traffic remains sessionless while 2025 traffic is isolated in an OTP-owned
  session connection.
- `MCP.Server.Handler` callbacks receive `ToolContext` and immutable launch
  configuration; callback results no longer replace handler state.
- `MCP.Server.Connection` replaces the removed per-session `MCP.Server` API.
- The request deadline now covers transport send, schema refresh, and MRTR
  resolver work. Callback failures are isolated to their request.

### Removed (original 2.0 cutover; legacy removals superseded above)

- The original cutover removed initialize/session handling, legacy resource
  subscriptions, held-open server requests, and protocol negotiation. The
  `2025-11-25` portions of that removal are restored by the dual-era
  compatibility entry above; revisions older than `2025-11-25` remain absent.
- Client result caching. Cache metadata remains visible to consumers.

### Security

- Identity is resolved per authenticated HTTP request or once at stdio launch
  and is carried only in `ToolContext`; model-controlled arguments and metadata
  cannot override it.
- Stateful HTTP sessions are principal-bound, supervised, capacity-limited,
  and reclaimed on idle/absolute expiry or endpoint shutdown.
- Request metadata, routing headers, extension values, cache policy, queue
  bounds, and tool routing annotations are validated at their boundaries.

## [1.1.0] - 2026-07-12

### Added
- **`handler_opts` request-identity seam** on `MCP.Transport.StreamableHTTP.Plug`. A new public
  Plug option threads request-scoped options into each session's handler `init/1`, so an
  authenticated Streamable-HTTP MCP server can bind a pipeline-established identity into handler
  state **without forking the Plug**. Two forms:
  - **Static** — `handler_opts: keyword()`, passed verbatim to `Handler.init/1`.
  - **Factory** — `handler_opts: (Plug.Conn.t() -> keyword())`, evaluated **once per session at
    the `initialize` request** against that request's `conn` (e.g. reading `conn.assigns` set by an
    upstream auth Plug), then bound for the session's lifetime.
- Validated against EMFA's consumer acceptance criteria (AC1–AC8) in the test suite, and by an
  external consumer running the seam in production against real Jira.

### Security
- Identity is established **server-side** by the authenticated Plug pipeline and bound at the
  `initialize` trust boundary — it is delivered to the handler via `init/1` opts and read from
  handler **state**, never supplied by the model as a tool-call argument (which is model-controlled
  and spoofable). The `conn` is never leaked into `handle_call_tool/3,4`, keeping handlers
  transport-agnostic. A factory that raises or returns a non-keyword fails the session cleanly at
  `initialize` (HTTP 500 / JSON-RPC -32603) with no session started and no server-side detail
  leaked to the client.

### Changed
- **Backward-compatible**: with no `handler_opts` (the default `[]`), behaviour is identical to
  prior releases — existing consumers are unaffected.
- **Docs**: clarified that the public Plug option is `server_mod:` (not the internal `MCP.Server`
  `handler:` key); documented the required client handshake ordering
  (`initialize → notifications/initialized → tools/call`; the per-session server stays `:waiting`
  until `notifications/initialized`); fixed the stale Examples link.

## [1.0.2] - 2026-07-07

### Changed
- Documentation only — no code changes. Updated `docs/prd.md`, `docs/architecture.md`, `docs/implementation-plan.md`, and `docs/onboarding.md` headers to reflect the `mcp_elixir_sdk` package name and current version (they still referred to the pre-rename `MCP Ex` / v0.2.1). Directory paths (`/workspace/elixir_code/mcp_ex/`) are intentionally left unchanged.

## [1.0.1] - 2026-04-16

### Changed
- **Renamed package** from `mcp_ex` to `mcp_elixir_sdk` (the `mcp_ex` hex name was previously taken by another client-only library). The new name follows the official MCP SDK naming convention (`mcp-go-sdk`, `mcp-python-sdk`, `mcp-ruby-sdk`, `mcp-typescript-sdk`).
- Top-level OTP application module renamed from `McpEx.Application` to `MCPElixirSDK.Application` (internal, not part of the public API).
- Default `client_info`/`server_info` name updated to `mcp_elixir_sdk`.

### Note
Public module names under the `MCP.*` namespace (e.g. `MCP.Client`, `MCP.Server`, `MCP.Server.Handler`, `MCP.Transport.*`) are unchanged, so existing code using these modules continues to work — only the dependency declaration needs updating.

## [1.0.0] - 2026-04-16

### Added
- First stable release (never published to hex — superseded by 1.0.1 due to package rename)
- 100% MCP conformance (Tier 1, 30/30 scenarios, 40/40 checks)
- Full hex package metadata, documentation, and usage rules for AI agents

## [0.2.3] - 2025-02-17

### Changed
- Updated documentation paths after workspace reorganization

## [0.2.2] - 2025-02-11

### Added
- Documented sampling timeout behavior over HTTP transport
- Added link to mcp_ex_examples repo in README

## [0.2.1] - 2025-02-11

### Changed
- Rewrote README with accurate usage examples

## [0.2.0] - 2025-02-09

### Added
- 100% MCP conformance (Tier 1) — 30/30 scenarios, 40/40 checks
- Async tool execution with `handle_call_tool/4` and `ToolContext`
- SSE streaming for intermediate messages during tool execution
- Client features: sampling, roots, elicitation callbacks
- Integration tests covering full client-server workflows

### Changed
- Phase 7 completion: conformance suite integration

## [0.1.0] - 2025-02-08

### Added
- Initial release
- MCP Client GenServer with full protocol API
- MCP Server GenServer with Handler behaviour
- Stdio transport (newline-delimited JSON-RPC)
- Streamable HTTP transport (POST + SSE) with Plug and Bandit
- Core protocol types, JSON-RPC 2.0 messages, capability negotiation
- Initialization handshake and capability auto-detection
- Pagination support for list operations
- Tools, resources, prompts, completions, and logging features

[1.0.1]: https://github.com/JohnSmall/mcp-elixir-sdk/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/JohnSmall/mcp-elixir-sdk/compare/v0.2.3...v1.0.0
[0.2.3]: https://github.com/JohnSmall/mcp-elixir-sdk/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/JohnSmall/mcp-elixir-sdk/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/JohnSmall/mcp-elixir-sdk/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/JohnSmall/mcp-elixir-sdk/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/JohnSmall/mcp-elixir-sdk/releases/tag/v0.1.0
