defmodule MCP.Protocol.MetaTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Meta

  @version "2026-07-28"

  defp params_with_meta(meta), do: %{"arguments" => %{}, "_meta" => meta}

  describe "from_params/1" do
    test "extracts the io.modelcontextprotocol/* keys" do
      meta =
        Meta.from_params(
          params_with_meta(%{
            "io.modelcontextprotocol/protocolVersion" => @version,
            "io.modelcontextprotocol/clientInfo" => %{"name" => "c", "version" => "1"},
            "io.modelcontextprotocol/clientCapabilities" => %{"sampling" => %{}},
            "io.modelcontextprotocol/logLevel" => "info"
          })
        )

      assert meta.protocol_version == @version
      assert meta.client_info == %{"name" => "c", "version" => "1"}
      assert meta.client_capabilities == %{"sampling" => %{}}
      assert meta.log_level == "info"
    end

    test "absent _meta yields an empty struct (no crash)" do
      assert %Meta{protocol_version: nil, raw: %{}} = Meta.from_params(%{"arguments" => %{}})
      assert %Meta{protocol_version: nil, raw: %{}} = Meta.from_params(nil)
    end
  end

  describe "validate_protocol_version/2" do
    test ":ok when the version matches" do
      meta = Meta.from_meta(%{"io.modelcontextprotocol/protocolVersion" => @version})
      assert Meta.validate_protocol_version(meta, @version) == :ok
    end

    test "missing version → {:error, :missing} (old-shape request)" do
      meta = Meta.from_meta(%{})
      assert Meta.validate_protocol_version(meta, @version) == {:error, :missing}
    end

    test "mismatched (e.g. legacy 2025-11-25) → {:error, {:unsupported, got}}" do
      meta = Meta.from_meta(%{"io.modelcontextprotocol/protocolVersion" => "2025-11-25"})

      assert Meta.validate_protocol_version(meta, @version) ==
               {:error, {:unsupported, "2025-11-25"}}
    end
  end

  describe "validate_required/1" do
    test "requires metadata, protocol version, and client capabilities" do
      assert Meta.validate_required(Meta.from_meta(%{})) == {:error, :missing_meta}

      assert Meta.validate_required(Meta.from_meta(%{"other" => true})) ==
               {:error, :missing_protocol_version}

      assert Meta.validate_required(
               Meta.from_meta(%{"io.modelcontextprotocol/protocolVersion" => @version})
             ) == {:error, :missing_client_capabilities}

      assert Meta.validate_required(
               Meta.from_meta(%{
                 "io.modelcontextprotocol/protocolVersion" => @version,
                 "io.modelcontextprotocol/clientCapabilities" => %{}
               })
             ) == :ok
    end
  end
end
