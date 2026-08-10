defmodule MCP.Protocol.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Capabilities.{ClientCapabilities, ServerCapabilities}

  describe "ServerCapabilities" do
    test "from_map/1 parses full capabilities" do
      map = %{
        "tools" => %{"listChanged" => true},
        "resources" => %{"subscribe" => true, "listChanged" => true},
        "prompts" => %{"listChanged" => true},
        "logging" => %{},
        "completions" => %{}
      }

      caps = ServerCapabilities.from_map(map)

      assert caps.tools.list_changed == true
      assert caps.resources.subscribe == true
      assert caps.resources.list_changed == true
      assert caps.prompts.list_changed == true
      assert %MCP.Protocol.Capabilities.LoggingCapabilities{} = caps.logging
      assert %MCP.Protocol.Capabilities.CompletionCapabilities{} = caps.completions
    end

    test "from_map/1 handles missing capabilities" do
      caps = ServerCapabilities.from_map(%{})

      assert caps.tools == nil
      assert caps.resources == nil
      assert caps.prompts == nil
      assert caps.logging == nil
      assert caps.completions == nil
    end

    test "from_map/1 handles experimental capabilities" do
      map = %{"experimental" => %{"custom" => %{"enabled" => true}}}
      caps = ServerCapabilities.from_map(map)
      assert caps.experimental == %{"custom" => %{"enabled" => true}}
    end

    test "round-trips through JSON" do
      map = %{
        "tools" => %{"listChanged" => true},
        "resources" => %{"subscribe" => true}
      }

      caps = ServerCapabilities.from_map(map)
      json = Jason.encode!(caps)
      decoded = Jason.decode!(json)

      assert decoded["tools"]["listChanged"] == true
      assert decoded["resources"]["subscribe"] == true
      refute Map.has_key?(decoded, "prompts")
      refute Map.has_key?(decoded, "logging")
    end

    test "round-trips extensions and unknown capability fields without rewriting keys" do
      map = %{
        "extensions" => %{
          "io.modelcontextprotocol/tasks" => %{},
          "com.example/widgets" => %{
            "nested" => %{"enabled" => true},
            "kinds" => ["a", "b"]
          }
        },
        "com.example/customCapability" => %{"level" => 2}
      }

      capabilities = ServerCapabilities.from_map(map)

      assert capabilities.extensions == map["extensions"]

      assert capabilities.extra == %{
               "com.example/customCapability" => %{"level" => 2}
             }

      assert Jason.decode!(Jason.encode!(capabilities)) == map
    end
  end

  describe "ClientCapabilities" do
    test "from_map/1 parses full capabilities" do
      map = %{
        "roots" => %{"listChanged" => true},
        "sampling" => %{},
        "elicitation" => %{"form" => %{}, "url" => %{}}
      }

      caps = ClientCapabilities.from_map(map)

      assert caps.roots.list_changed == true
      assert %MCP.Protocol.Capabilities.SamplingCapabilities{} = caps.sampling
      assert caps.elicitation.form == %{}
      assert caps.elicitation.url == %{}
    end

    test "from_map/1 handles empty map" do
      caps = ClientCapabilities.from_map(%{})

      assert caps.roots == nil
      assert caps.sampling == nil
      assert caps.elicitation == nil
    end

    test "round-trips through JSON" do
      map = %{
        "roots" => %{"listChanged" => true},
        "sampling" => %{}
      }

      caps = ClientCapabilities.from_map(map)
      json = Jason.encode!(caps)
      decoded = Jason.decode!(json)

      assert decoded["roots"]["listChanged"] == true
      assert decoded["sampling"] == %{}
      refute Map.has_key?(decoded, "elicitation")
    end

    test "round-trips extensions separately from experimental and preserves unknown fields" do
      map = %{
        "extensions" => %{"com.example/ui" => %{"mimeTypes" => ["text/html"]}},
        "experimental" => %{"draft" => %{}},
        "vendorCapability" => false
      }

      capabilities = ClientCapabilities.from_map(map)

      assert capabilities.extensions == map["extensions"]
      assert capabilities.experimental == map["experimental"]
      assert capabilities.extra == %{"vendorCapability" => false}
      assert Jason.decode!(Jason.encode!(capabilities)) == map
    end
  end

  describe "extension validation" do
    test "rejects identifiers without a valid mandatory prefix" do
      invalid = [
        "tasks",
        "/tasks",
        "1com.example/tasks",
        "com..example/tasks",
        "com.example/-tasks",
        "com.example/tasks_"
      ]

      for identifier <- invalid do
        assert_raise ArgumentError, ~r/invalid_extension_identifier/, fn ->
          ServerCapabilities.from_map(%{"extensions" => %{identifier => %{}}})
        end
      end
    end

    test "accepts the complete meta-key label and name grammar" do
      valid = [
        "com.example/tasks",
        "a-b.example-2/name_with.dots-and-hyphens",
        "io.modelcontextprotocol/tasks",
        "com.example/"
      ]

      extensions = Map.new(valid, &{&1, %{}})
      assert ClientCapabilities.from_map(%{"extensions" => extensions}).extensions == extensions
    end

    test "rejects non-object or non-JSON extension settings" do
      for settings <- [nil, true, [], "enabled", %{"bad" => self()}] do
        assert_raise ArgumentError, ~r/invalid_extension_settings/, fn ->
          ClientCapabilities.from_map(%{
            "extensions" => %{"com.example/widgets" => settings}
          })
        end
      end
    end

    test "rejects direct extra-field collisions and non-JSON values on encoding" do
      assert_raise ArgumentError, ~r/collide/, fn ->
        Jason.encode!(%ClientCapabilities{extra: %{"roots" => %{}}})
      end

      assert_raise ArgumentError, ~r/string-keyed JSON/, fn ->
        Jason.encode!(%ServerCapabilities{extra: %{"bad" => self()}})
      end
    end
  end
end
