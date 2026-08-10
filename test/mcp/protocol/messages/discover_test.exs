defmodule MCP.Protocol.Messages.DiscoverTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Capabilities.ServerCapabilities
  alias MCP.Protocol.Messages.Discover
  alias MCP.Protocol.Types.Implementation

  # Wire shape pinned to published-final 2026-07-28 schema 5f5440bb26a62e2cf3440b92da5a667efa03b267,
  # schema/2026-07-28/schema.ts
  # (DiscoverResult extends CacheableResult): supportedVersions + resultType/
  # ttlMs/cacheScope; serverInfo under _meta["io.modelcontextprotocol/serverInfo"].

  test "to_map/1 produces the schema shape" do
    result = %Discover.Result{
      supported_versions: ["2026-07-28"],
      capabilities: %ServerCapabilities{},
      server_info: %Implementation{name: "mcp_elixir_sdk", version: "2.0.0"},
      instructions: "hello"
    }

    map = Discover.Result.to_map(result)

    assert map["supportedVersions"] == ["2026-07-28"]
    assert map["resultType"] == "complete"
    assert map["ttlMs"] == 0
    assert map["cacheScope"] == "public"
    assert map["instructions"] == "hello"
    assert is_map(map["capabilities"])
    assert map["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "mcp_elixir_sdk"
    # server identity is NOT top-level; supportedVersions replaces protocolVersions
    refute Map.has_key?(map, "serverInfo")
    refute Map.has_key?(map, "protocolVersions")
  end

  test "from_map/1 round-trips the schema shape" do
    map = %{
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{},
      "resultType" => "complete",
      "ttlMs" => 0,
      "cacheScope" => "public",
      "_meta" => %{"io.modelcontextprotocol/serverInfo" => %{"name" => "s", "version" => "2.0.0"}}
    }

    result = Discover.Result.from_map(map)
    assert result.supported_versions == ["2026-07-28"]
    assert result.cache_scope == "public"
    assert result.server_info.name == "s"
  end

  test "unknown discovery result fields survive typed round trips" do
    map = %{
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{},
      "vendorDiscovery" => [false, nil, 0]
    }

    result = Discover.Result.from_map(map)

    assert result.extra == %{"vendorDiscovery" => [false, nil, 0]}
    assert Discover.Result.to_map(result)["vendorDiscovery"] == [false, nil, 0]
  end
end
