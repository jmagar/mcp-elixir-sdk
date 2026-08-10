# MCP Elixir SDK 2.0 Types

**Status:** Normative target shapes with current gaps identified
**Wire source:** MCP `2026-07-28` schema pinned at `5f5440b`, plus the
`2025-11-25` and `2025-06-18` core compatibility schemas
**Contracts:** [contracts.md](contracts.md)

This document owns protocol and public-domain type shapes. It does not own OTP
process state; see [runtime-models.md](runtime-models.md). “Current” means the
type exists on the `2.0.0-dev.1` baseline or the S1 working tree. “Target” means
it must be added by the named slice.

## Representation rules

Wire keys are JSON strings in camelCase. Elixir structs use snake_case fields
and explicit conversion functions or `Jason.Encoder` implementations.

```elixir
@type json_scalar :: nil | boolean() | number() | String.t()
@type json_value :: json_scalar() | [json_value()] | json_object()
@type json_object :: %{required(String.t()) => json_value()}
@type request_id :: String.t() | integer()
@type cursor :: String.t() | nil
@type protocol_version :: "2026-07-28" | "2025-11-25" | "2025-06-18"
@type protocol_mode :: :stateless | :legacy
@type extra_fields :: %{optional(String.t()) => json_value()}
```

Remote keys MUST remain strings. `String.to_atom/1` is forbidden on protocol
input. Optional values are omitted only when absent; valid JSON values
(`false`, `0`, `""`, `[]`, and `nil` when the field permits JSON null) must not
be dropped by truthiness checks.

Unknown members are preserved only where the pinned schema defines an open
boundary. Typed request-param, result, and capability structs at those
boundaries contain an `extra: extra_fields()` member. `_meta` keeps a canonical
`raw` map. JSON Schema objects and extension settings remain opaque string-keyed
maps. Closed protocol objects reject unknown members with a stable decoding
error rather than silently promising universal preservation.

## JSON-RPC envelope types — current

| Elixir module | Required fields | Notes |
| --- | --- | --- |
| `MCP.Protocol.Messages.Request` | `jsonrpc`, `id`, `method` | `params` is optional map data |
| `MCP.Protocol.Messages.Notification` | `jsonrpc`, `method` | No request ID |
| `MCP.Protocol.Messages.Response` | `jsonrpc`, `id`, one of result/error | Result and error are mutually exclusive on the wire |
| `MCP.Protocol.Error` | `code`, `message` | `data` optional |

`request_id` intentionally excludes floats and null. IDs are correlation keys,
not database identifiers.

## Metadata types — current

`MCP.Protocol.Meta` is the parsed view of request `_meta`:

```elixir
%MCP.Protocol.Meta{
  protocol_version: String.t() | nil,
  client_info: map() | nil,
  client_capabilities: map() | nil,
  log_level: String.t() | nil,
  trace_context: map() | nil,
  raw: map()
}
```

The `raw` map is canonical for preservation. Parsed fields are conveniences;
they do not authorize deletion of unknown keys.

Legacy initialize types retain `protocolVersion`, `capabilities`,
`clientInfo`/`serverInfo`, and optional instructions in their 2025 wire shape.
The internal legacy adapter may add 2026 metadata only for dispatch validation;
that data is neither part of the legacy type nor visible to handlers.

Reserved keys used by 2.0:

| Key | Value |
| --- | --- |
| `io.modelcontextprotocol/protocolVersion` | string |
| `io.modelcontextprotocol/clientInfo` | implementation object |
| `io.modelcontextprotocol/clientCapabilities` | client capabilities object |
| `io.modelcontextprotocol/logLevel` | logging level string |
| `io.modelcontextprotocol/serverInfo` | implementation object on results |
| `io.modelcontextprotocol/subscriptionId` | request ID on subscription messages |

## Capability types

### Current shape

`MCP.Protocol.Capabilities.ClientCapabilities` contains `roots`, `sampling`,
`elicitation`, and `experimental`. `ServerCapabilities` contains `tools`,
`resources`, `prompts`, `logging`, `completions`, and `experimental`.

### S3 target shape

Both structs gain:

```elixir
extensions: %{optional(String.t()) => json_object()} | nil,
extra: extra_fields()
```

`extensions` is not merged with `experimental`. The constructor/decoder returns
a stable error for an invalid extension key or a non-object settings value.
Valid empty settings (`%{}`) represent support without settings.
Unknown capability names are stored in `extra` because capability objects are
open sets in the pinned schema. Known fields and `extra` keys must be disjoint;
constructors reject collisions rather than choosing an arbitrary winner.

An extension identifier is valid when it follows the `_meta` naming grammar and
has a mandatory prefix before `/`, for example:

```text
io.modelcontextprotocol/tasks
com.example/widgets
```

An unprefixed key such as `tasks` is invalid.

## Discovery types — current

`MCP.Protocol.Messages.Discover.Result` represents `DiscoverResult`:

```elixir
%MCP.Protocol.Messages.Discover.Result{
  supported_versions: [String.t()],
  capabilities: MCP.Protocol.Capabilities.ServerCapabilities.t(),
  instructions: String.t() | nil,
  server_info: MCP.Protocol.Types.Implementation.t() | nil,
  meta: map() | nil,
  result_type: "complete",
  ttl_ms: non_neg_integer(),
  cache_scope: String.t()
}
```

`server_info` is encoded under result `_meta`, not as a top-level wire member.
S3 changes only the nested capability structs.

## Tool types

### Tool definition — current, tightened by S4

```elixir
%MCP.Protocol.Types.Tool{
  name: String.t(),
  title: String.t() | nil,
  description: String.t() | nil,
  input_schema: json_object(),
  output_schema: json_object() | nil,
  annotations: MCP.Protocol.Types.ToolAnnotations.t() | nil,
  icons: [MCP.Protocol.Types.Icon.t()] | nil,
  meta: map() | nil
}
```

S4 adds validation that `input_schema["type"] == "object"` without filtering
other JSON Schema 2020-12 keywords. `output_schema` remains an arbitrary schema
object and has no object-root constraint.

`x-mcp-header` is protocol-defined data inside an input-schema property. The
type layer preserves it unchanged. S4a adds lossless schema representation;
S1b performs the complete name, location, primitive-type, uniqueness, and safe
integer validation defined by [contracts.md](contracts.md#c2--http-routing-headers).
Transport-independent consumers do not interpret it.

### Tool call result — S4 correction

The current `MCP.Protocol.Messages.Tools.CallResult` types
`structured_content` as `map() | nil`. The target is:

```elixir
@type structured_content :: json_value() | :absent

%MCP.Protocol.Messages.Tools.CallResult{
  content: [MCP.Protocol.Types.Content.content_block()],
  structured_content: structured_content(), # default: :absent
  is_error: boolean() | nil,
  meta: map() | nil,
  extra: extra_fields()
}
```

`structured_content: :absent` means the wire member is absent. `nil` means the
member is present with JSON null. The encoder omits only `:absent`; the decoder
uses `Map.fetch/2` so it can preserve this distinction. Because `json_value`
excludes atoms, the sentinel cannot collide with valid protocol data.

## Subscription types — S2 target

Each public module should live in its own file even when its module name shares
a namespace.

### `MCP.Protocol.Types.SubscriptionFilter`

```elixir
defstruct tools_list_changed: false,
          prompts_list_changed: false,
          resources_list_changed: false,
          resource_subscriptions: []

@type t :: %__MODULE__{
  tools_list_changed: boolean(),
  prompts_list_changed: boolean(),
  resources_list_changed: boolean(),
  resource_subscriptions: [String.t()]
}
```

Wire mapping:

| Elixir | JSON |
| --- | --- |
| `tools_list_changed` | `toolsListChanged` |
| `prompts_list_changed` | `promptsListChanged` |
| `resources_list_changed` | `resourcesListChanged` |
| `resource_subscriptions` | `resourceSubscriptions` |

Omitted and `false` are equivalent for boolean opt-ins. URI order and duplicate
entries are preserved because the protocol defines no normalization rule.
Matching uses URI equality without mutating the public value.

### `MCP.Protocol.Messages.Subscriptions.ListenParams`

```elixir
defstruct [:notifications, :meta]

@type t :: %__MODULE__{
  notifications: MCP.Protocol.Types.SubscriptionFilter.t(),
  meta: map()
}
```

`meta` is required on outgoing 2026 requests after client enrichment, even if a
low-level constructor temporarily accepts nil before enrichment.

### `MCP.Protocol.Messages.Subscriptions.AcknowledgedParams`

```elixir
defstruct [:notifications, :meta]

@type t :: %__MODULE__{
  notifications: MCP.Protocol.Types.SubscriptionFilter.t(),
  meta: map()
}
```

Its `_meta` must contain the subscription ID. `notifications` is a subset of the
requested filter.

### `MCP.Protocol.Messages.Subscriptions.ListenResult`

```elixir
defstruct [:meta, result_type: "complete"]

@type t :: %__MODULE__{
  meta: map(),
  result_type: "complete"
}
```

The final result requires literal `resultType: "complete"` and has no payload
beyond base result fields and required metadata.

### `MCP.Client.SubscriptionHandle`

```elixir
@opaque t :: %__MODULE__{
  id: request_id(),
  worker: pid(),
  monitor_ref: reference()
}

listen_subscriptions(client, filter, opts \\ []) :: {:ok, t()} | {:error, term()}
next(t(), timeout()) :: {:ok, map()} | {:error, :closed | :queue_overflow | term()}
close(t()) :: :ok
```

The handle is an ownership token, not protocol data. `close/1` is idempotent;
callers do not send messages directly to `worker`.

## Resource, prompt, and content types — current

| Family | Principal modules | Boundary note |
| --- | --- | --- |
| Resources | `Resource`, `ResourceTemplate`, `ResourceContents`, resource messages | URIs stay strings; missing resources use Invalid Params in the 2026 target |
| Prompts | `Prompt`, `PromptArgument`, `PromptMessage`, prompt messages | Prompt routing target is `params.name` |
| Content | `TextContent`, `ImageContent`, `AudioContent`, `EmbeddedResource`, `ResourceLink` | Discriminated by wire `type` |
| Sampling | `SamplingMessage`, `ModelPreferences`, sampling messages | Retained but deprecated in 2026; MRTR transports input |
| Elicitation | elicitation messages | Form and URL shapes retained; MRTR transports input |
| Roots | `Root`, roots messages | Retained but deprecated in 2026 |

Deprecation means “still represented for this protocol version,” not “safe to
delete during 2.0 hardening.”

## Cacheable result types — S5 target normalization

List, read, and discovery results that extend `CacheableResult` share:

```elixir
@type result_type :: "complete" | "input_required" | String.t()
@type cache_scope :: "public" | "private" | String.t()

result_type: result_type()
ttl_ms: non_neg_integer()
cache_scope: cache_scope()
extra: extra_fields()
```

These fields should be implemented through a common conversion helper or
protocol-level type contract so individual result modules cannot drift. This is
a serialization abstraction, not a process or persistence model.

## Type verification matrix

| Type family | Round trip | Invalid input | Unknown fields | Falsey values |
| --- | ---: | ---: | ---: | ---: |
| JSON-RPC envelopes | Required | Required | Preserve only at open params/results boundaries | Required |
| `_meta` | Required | Required for reserved fields | Preserve all | Required |
| Capabilities/extensions | Required | Required | Preserve valid extension settings | Empty object required |
| Tool schemas | Required | Required root checks | Preserve all schema keywords | Required |
| Structured content | Required | JSON-only | N/A | All JSON kinds required |
| Subscriptions | Required | Required filter checks | Preserve request-param extras; reject unknown closed filter keys | Explicit false equivalent to omitted |

## Authoritative sources

- [Pinned MCP schema](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/5f5440bb26a62e2cf3440b92da5a667efa03b267/schema/2026-07-28/schema.ts)
- Current implementations under `lib/mcp/protocol/`
- [S4 requirements](specifications.md#s4--json-schema-2020-12)

## Current implementation anchors

- JSON-RPC request envelope:
  [`request.ex:9`](../../lib/mcp/protocol/messages/request.ex#L9)
- Parsed metadata type: [`meta.ex:46`](../../lib/mcp/protocol/meta.ex#L46)
- Discovery result:
  [`discover.ex:28`](../../lib/mcp/protocol/messages/discover.ex#L28)
- Tool definition: [`tool.ex:11`](../../lib/mcp/protocol/types/tool.ex#L11)
- Tool result and current `map() | nil` narrowing:
  [`tools.ex:117`](../../lib/mcp/protocol/messages/tools.ex#L117)
- Capability structs:
  [`client_capabilities.ex:13`](../../lib/mcp/protocol/capabilities/client_capabilities.ex#L13) and
  [`server_capabilities.ex:15`](../../lib/mcp/protocol/capabilities/server_capabilities.ex#L15)
