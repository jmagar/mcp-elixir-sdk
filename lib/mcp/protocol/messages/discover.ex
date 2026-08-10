defmodule MCP.Protocol.Messages.Discover do
  @moduledoc """
  Message types for `server/discover` (MCP 2026-07-28 stateless core, SEP-2575).

  With the `initialize` handshake removed, a server MUST implement
  `server/discover` so clients can learn its supported protocol versions,
  capabilities, and identity up-front.

  ## Wire shape — verified against the published-final schema

  Pinned to the published-final `2026-07-28` schema at commit
  `5f5440bb26a62e2cf3440b92da5a667efa03b267` (tag `2026-07-28`, 2026-07-28),
  `schema/2026-07-28/schema.ts`:

    * `LATEST_PROTOCOL_VERSION = "2026-07-28"` (schema.ts:30).
    * `DiscoverResult extends CacheableResult` (schema.ts:678); the field is
      **`supportedVersions: string[]`** (schema.ts:683), *not* `protocolVersions`.
    * `CacheableResult extends Result` adds **`ttlMs`** / **`cacheScope`**
      (schema.ts:1094/1109); `Result` carries **`resultType`** (`"complete" |
      "input_required" | string`). These three are **structural fields** here;
      caching **semantics/policy** are MES-9 scope, so this SDK emits structural
      defaults (`resultType: "complete"`, `ttlMs: 0`, `cacheScope: "public"`).
    * Server identity is under **`_meta["io.modelcontextprotocol/serverInfo"]`**
      (example `DiscoverResult/server-capabilities-discovery.json`), *not* a
      top-level `serverInfo`.
  """

  defmodule Result do
    @moduledoc """
    Result of `server/discover` — `DiscoverResult extends CacheableResult`.
    """

    alias MCP.Protocol.Capabilities.ServerCapabilities
    alias MCP.Protocol.Types.Implementation

    @server_info_meta_key "io.modelcontextprotocol/serverInfo"

    defstruct [
      :supported_versions,
      :capabilities,
      :instructions,
      :server_info,
      :meta,
      extra: %{},
      result_type: "complete",
      ttl_ms: 0,
      cache_scope: "public"
    ]

    @type t :: %__MODULE__{
            supported_versions: [String.t()],
            capabilities: ServerCapabilities.t(),
            instructions: String.t() | nil,
            server_info: Implementation.t() | nil,
            meta: map() | nil,
            result_type: String.t(),
            ttl_ms: non_neg_integer(),
            cache_scope: String.t(),
            extra: %{optional(String.t()) => MCP.Protocol.json_value()}
          }

    def server_info_meta_key, do: @server_info_meta_key

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      meta = Map.get(map, "_meta") || %{}

      server_info =
        case Map.get(meta, @server_info_meta_key) do
          nil -> nil
          impl -> Implementation.from_map(impl)
        end

      %__MODULE__{
        supported_versions: Map.get(map, "supportedVersions", []),
        capabilities: map |> Map.fetch!("capabilities") |> ServerCapabilities.from_map(),
        instructions: Map.get(map, "instructions"),
        result_type: Map.get(map, "resultType", "complete"),
        ttl_ms: Map.get(map, "ttlMs", 0),
        cache_scope: Map.get(map, "cacheScope", "public"),
        server_info: server_info,
        meta: meta,
        extra:
          Map.drop(map, [
            "supportedVersions",
            "capabilities",
            "instructions",
            "resultType",
            "ttlMs",
            "cacheScope",
            "_meta"
          ])
      }
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = result) do
      meta =
        (result.meta || %{})
        |> put_server_info(result.server_info)

      map =
        Map.merge(result.extra, %{
          "supportedVersions" => result.supported_versions,
          "capabilities" => Jason.decode!(Jason.encode!(result.capabilities)),
          "resultType" => result.result_type,
          "ttlMs" => result.ttl_ms,
          "cacheScope" => result.cache_scope
        })

      map =
        if result.instructions, do: Map.put(map, "instructions", result.instructions), else: map

      if map_size(meta) > 0, do: Map.put(map, "_meta", meta), else: map
    end

    defp put_server_info(meta, nil), do: meta

    defp put_server_info(meta, %Implementation{} = impl) do
      Map.put(meta, @server_info_meta_key, Jason.decode!(Jason.encode!(impl)))
    end
  end
end
