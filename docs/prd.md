# Product Requirements Document: MCP Elixir SDK

> **Archived 1.x planning record.** This document describes the superseded
> stateful `2025-11-25` design. It is retained for project history and is not
> current SDK guidance. See [README.md](../README.md),
> [architecture.md](architecture.md), and
> [SDK 2.0 specifications](sdk-2.0/specifications.md) for the implemented
> `2026-07-28` stateless core.

## Document Info
- **Project**: MCP Elixir SDK — Elixir implementation of the Model Context Protocol
- **Hex package**: `mcp_elixir_sdk`
- **Version**: 1.0.2
- **Date**: 2026-02-09
- **Status**: Phase 7 Complete — 100% Conformance (Tier 1)
- **Protocol**: MCP 2025-11-25
- **GitHub**: github.com/JohnSmall/mcp-elixir-sdk
- **Local directory**: `/workspace/elixir_code/mcp_ex/` (not renamed)

---

## 1. Executive Summary

`mcp_elixir_sdk` is a standalone Elixir library implementing the [Model Context Protocol](https://modelcontextprotocol.io/) (MCP), an open protocol for integrating LLM applications with external tools and data sources. The library provides both **client** and **server** implementations with pluggable transports (stdio, Streamable HTTP).

MCP is to AI tool integration what LSP (Language Server Protocol) is to code editors — a universal standard replacing N×M custom integrations with a single protocol.

---

## 2. Background and Motivation

### 2.1 What is MCP?

MCP enables standardized communication between:
- **Hosts**: LLM applications (e.g., Claude Desktop, IDEs, chat interfaces)
- **Clients**: Connectors within the host application (one per server connection)
- **Servers**: Services providing tools, resources, and prompts

The protocol uses JSON-RPC 2.0 over stateful connections with capability negotiation.

### 2.2 Why Elixir?

- **BEAM processes** map naturally to per-connection client/server sessions
- **GenServer** provides lifecycle management for stateful MCP sessions
- **OTP supervision** provides fault tolerance for long-lived connections
- **Streams** handle SSE event streams naturally
- **Ports** provide native subprocess management for stdio transport
- **Plug/Bandit** can serve Streamable HTTP transport (optional dep)

### 2.3 Why a Separate Package?

MCP is a general-purpose protocol — not specific to the ADK. Any Elixir application (Phoenix apps, LiveView, CLI tools, Nerves devices) may want MCP client or server capabilities. Keeping it standalone follows the `adk_ex` / `adk_ex_ecto` separation pattern.

The ADK integration is a thin adapter: `ADK.Tool.McpToolset` wraps `MCP.Client` as an `ADK.Tool.Toolset` behaviour implementation.

### 2.3 Reference Materials

- **MCP Specification (2025-11-25)**: https://modelcontextprotocol.io/specification/2025-11-25
- **TypeScript schema (source of truth)**: https://github.com/modelcontextprotocol/specification/blob/main/schema/2025-11-25/schema.ts
- **Go SDK**: https://github.com/modelcontextprotocol/go-sdk
- **Python SDK**: https://github.com/modelcontextprotocol/python-sdk
- **Ruby SDK**: https://github.com/modelcontextprotocol/ruby-sdk
- **Conformance tests**: https://github.com/modelcontextprotocol/conformance
- **SDK tiers**: https://modelcontextprotocol.io/community/sdk-tiers

---

## 3. Goals and Non-Goals

### 3.1 Goals

1. **Full MCP 2025-11-25 protocol support** — All non-experimental features
2. **Client and server in one package** — Shared types and protocol code
3. **Pluggable transports** — stdio and Streamable HTTP built-in, custom transports via behaviour
4. **Conformance tested** — Integrate with official MCP conformance test suite
5. **Idiomatic Elixir** — OTP patterns, behaviours, GenServers, streams
6. **ADK-compatible** — Easy to wrap as `ADK.Tool.Toolset` for agent tool integration
7. **Tier 1 SDK achieved** — 100% conformance pass rate (30/30 scenarios, 40/40 checks)

### 3.2 Non-Goals

- OAuth/authorization implementation (defer to future phase or separate package)
- Experimental features (Tasks) until they stabilize
- Built-in HTTP server (use Plug/Bandit as optional dep for Streamable HTTP server)
- MCP Apps protocol extensions
- GUI or CLI tools for MCP

---

## 4. Protocol Features

### 4.1 Server Features (server provides to client)

| Feature | MCP Method | Priority |
|---------|-----------|----------|
| **Tools** | `tools/list`, `tools/call` | P0 — Core |
| **Resources** | `resources/list`, `resources/read`, `resources/subscribe`, `resources/templates/list` | P0 — Core |
| **Prompts** | `prompts/list`, `prompts/get` | P0 — Core |
| **Logging** | `logging/setLevel`, `notifications/message` | P1 |
| **Completions** | `completion/complete` | P2 |
| **Pagination** | `cursor`/`nextCursor` on list operations | P1 |
| **Change notifications** | `notifications/tools/list_changed`, etc. | P1 |

### 4.2 Client Features (client provides to server)

| Feature | MCP Method | Priority |
|---------|-----------|----------|
| **Sampling** | `sampling/createMessage` | P1 |
| **Roots** | `roots/list`, `notifications/roots/list_changed` | P1 |
| **Elicitation** | `elicitation/create` (form + URL modes) | P2 |

### 4.3 Base Protocol

| Feature | Priority |
|---------|----------|
| JSON-RPC 2.0 message framing | P0 |
| Initialize / initialized handshake | P0 |
| Capability negotiation | P0 |
| Ping/pong | P0 |
| Progress notifications | P1 |
| Cancellation | P1 |
| Error handling (protocol + application) | P0 |

### 4.4 Transports

| Transport | Priority |
|-----------|----------|
| **stdio** (subprocess, newline-delimited) | P0 |
| **Streamable HTTP** (POST + SSE, session management) | P1 |
| Custom transport behaviour | P0 |

---

## 5. Data Types (from MCP spec)

### 5.1 Core Types

| Type | Description |
|------|-------------|
| `Tool` | name, title, description, inputSchema, outputSchema, annotations, icons |
| `Resource` | uri, name, title, description, mimeType, size, annotations, icons |
| `ResourceTemplate` | uriTemplate, name, title, description, mimeType, icons |
| `Prompt` | name, title, description, arguments, icons |
| `PromptMessage` | role, content (text/image/audio/resource) |
| `Content` | TextContent, ImageContent, AudioContent, ResourceContent, ResourceLink |
| `ToolResult` | content (array), structuredContent (optional), isError |
| `Implementation` | name, version, title, description, icons, websiteUrl |

### 5.2 Capability Types

| Side | Capabilities |
|------|-------------|
| Server | tools, resources, prompts, logging, completions, experimental |
| Client | roots, sampling, elicitation, experimental |

### 5.3 Sampling Types

| Type | Description |
|------|-------------|
| `CreateMessageRequest` | messages, modelPreferences, systemPrompt, maxTokens, tools, toolChoice |
| `CreateMessageResult` | role, content, model, stopReason |
| `ModelPreferences` | hints, costPriority, speedPriority, intelligencePriority |

---

## 6. Technical Constraints

- **Elixir**: >= 1.17
- **OTP**: >= 26
- **Runtime deps**: jason (JSON), elixir_uuid or nanoid (IDs)
- **Optional deps**: req (HTTP client for Streamable HTTP client), plug + bandit (HTTP server for Streamable HTTP server)
- **No ADK dependency** — mcp_elixir_sdk is standalone
- **No mandatory HTTP deps** — stdio transport works with zero HTTP deps
- **Conformance testing** via npx (Node.js required in CI only)

---

## 7. Success Criteria

1. Client can connect to any MCP server (stdio + Streamable HTTP)
2. Server can serve any MCP client (stdio + Streamable HTTP)
3. Full tools/resources/prompts support (list, call/read/get, change notifications)
4. Sampling and roots client features
5. 100% conformance test pass rate (Tier 1) — achieved
6. Clean: tests pass, credo clean, dialyzer clean
7. Works as `ADK.Tool.Toolset` adapter for `adk_ex`
8. Publishable to hex.pm
