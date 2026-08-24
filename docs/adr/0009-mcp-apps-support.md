# ADR-009: Stable MCP Apps support

**Status:** Accepted
**Date:** 2026-08-24

## Decision

The SDK supports the stable MCP Apps extension defined by SEP-1865 version
`2026-01-26`. The extension identifier is `io.modelcontextprotocol/ui`, the
HTML profile is `text/html;profile=mcp-app`, and canonical tool linkage is
`_meta.ui.resourceUri` to an exact `ui://` resource.

Support covers extension capability helpers, lossless metadata/resource wire
types, bounded validation, immutable authoring definitions, exact-client
resource resolution, and pure app/host bridge codecs and lifecycle validation.
Unknown string-key JSON members are preserved but never interpreted as grants,
routing, linkage, or visibility.

Browser iframe rendering and JavaScript `postMessage` execution are not BEAM
SDK responsibilities. The embedding host enforces sandboxing, effective CSP
and permissions, consent, visibility, and same-server routing. Stable MCP does
not convey trustworthy iframe/model provenance to a remote server; `_meta`,
arguments, or ad hoc headers must never be treated as such provenance.

## Security and performance boundaries

- UI resources require an exact `ui://` URI, exact profile MIME type, matching
  read URI, and exactly one bounded text/blob body.
- CSP and permission values are declarations, not grants. Hosts can tighten
  them but cannot infer approval from server metadata.
- Resolution performs one exact `resources/read`; the SDK does not scan,
  prefetch, retry, or cache App resources.
- Raw wire metadata remains distinct from any allowlisted View projection.
- Apps validation stays outside shared HTTP/stdio hot paths.

## Compatibility and evidence

Nested linkage is emitted canonically. The deprecated flat
`_meta["ui/resourceUri"]` is accepted only as compatibility input and conflicts
with a different nested value.

MCP core conformance and MCP Apps evidence are separate denominators. Local
unit/transport fixtures do not prove real-browser hydration. The optional
`MCP Apps browser interoperability` workflow reports that boundary separately:
it uses a fresh official Inspector host with a token-authenticated control API;
the fixture MCP server is unauthenticated. It captures the host version,
resource-policy probe, screenshots, console/network errors, and
server-side proof of `resources/read` plus the View's same-server callback. It
does not gate package CI or add Hex runtime dependencies.
