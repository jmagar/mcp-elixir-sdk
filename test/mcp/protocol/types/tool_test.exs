defmodule MCP.Protocol.Types.ToolTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Types.Tool

  @tool_map %{
    "name" => "get_weather",
    "title" => "Get Weather",
    "description" => "Get current weather for a city",
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{
        "city" => %{"type" => "string"}
      },
      "required" => ["city"]
    }
  }

  describe "from_map/1" do
    test "parses a tool with required fields" do
      tool = Tool.from_map(@tool_map)

      assert tool.name == "get_weather"
      assert tool.title == "Get Weather"
      assert tool.description == "Get current weather for a city"
      assert tool.input_schema["type"] == "object"
    end

    test "parses a tool with annotations" do
      map =
        Map.put(@tool_map, "annotations", %{
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "title" => "Weather Lookup"
        })

      tool = Tool.from_map(map)
      assert tool.annotations.read_only_hint == true
      assert tool.annotations.destructive_hint == false
      assert tool.annotations.title == "Weather Lookup"
    end

    test "parses a tool with outputSchema" do
      map =
        Map.put(@tool_map, "outputSchema", %{
          "type" => "object",
          "properties" => %{"temp" => %{"type" => "number"}}
        })

      tool = Tool.from_map(map)
      assert tool.output_schema["type"] == "object"
    end

    test "parses a tool with icons" do
      map =
        Map.put(@tool_map, "icons", [
          %{"src" => "https://example.com/icon.png", "mimeType" => "image/png"}
        ])

      tool = Tool.from_map(map)
      assert length(tool.icons) == 1
      assert hd(tool.icons).src == "https://example.com/icon.png"
    end

    test "parses a tool with _meta" do
      map = Map.put(@tool_map, "_meta", %{"custom" => "value"})
      tool = Tool.from_map(map)
      assert tool.meta == %{"custom" => "value"}
    end
  end

  describe "JSON encoding" do
    test "round-trips through JSON with camelCase keys" do
      tool = Tool.from_map(@tool_map)
      json = Jason.encode!(tool)
      decoded = Jason.decode!(json)

      assert decoded["name"] == "get_weather"
      assert decoded["inputSchema"]["type"] == "object"
      refute Map.has_key?(decoded, "input_schema")
      refute Map.has_key?(decoded, "outputSchema")
    end

    test "omits nil fields" do
      tool = Tool.from_map(@tool_map)
      json = Jason.encode!(tool)
      decoded = Jason.decode!(json)

      refute Map.has_key?(decoded, "annotations")
      refute Map.has_key?(decoded, "icons")
      refute Map.has_key?(decoded, "_meta")
    end
  end

  describe "JSON Schema 2020-12 preservation" do
    test "round-trips nested input-schema keywords and x-mcp-header annotations unchanged" do
      schema = %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "$defs" => %{
          "region" => %{"type" => "string", "enum" => ["us-east", "eu-west"]}
        },
        "properties" => %{
          "region" => %{"$ref" => "#/$defs/region", "x-mcp-header" => "Region"},
          "mode" => %{"oneOf" => [%{"const" => "fast"}, %{"const" => "safe"}]}
        },
        "if" => %{"properties" => %{"mode" => %{"const" => "safe"}}},
        "then" => %{"required" => ["region"]},
        "x-unknown-keyword" => %{"nested" => [true, nil, 1]}
      }

      decoded =
        @tool_map
        |> Map.put("inputSchema", schema)
        |> Tool.from_map()
        |> Jason.encode!()
        |> Jason.decode!()

      assert decoded["inputSchema"] == schema
    end

    test "requires outputSchema to be a JSON object" do
      for invalid <- [true, false, [], "schema", 1] do
        assert_raise ArgumentError, ~r/outputSchema must be a JSON object/, fn ->
          @tool_map |> Map.put("outputSchema", invalid) |> Tool.from_map()
        end
      end
    end

    test "preserves unknown tool members at the open type boundary" do
      decoded =
        @tool_map
        |> Map.put("vendorField", %{"enabled" => false})
        |> Tool.from_map()
        |> Jason.encode!()
        |> Jason.decode!()

      assert decoded["vendorField"] == %{"enabled" => false}
    end

    test "rejects known-field collisions in manually constructed extras" do
      tool = Tool.from_map(@tool_map)

      assert_raise ArgumentError, ~r/tool extra field collides with name/, fn ->
        Jason.encode!(%{tool | extra: %{"name" => "ambiguous"}})
      end

      assert_raise ArgumentError, ~r/field names must be strings/, fn ->
        Jason.encode!(%{tool | extra: %{name: "ambiguous"}})
      end
    end

    test "rejects an input schema whose root is not explicitly an object" do
      for invalid <- [true, %{}, %{"type" => "string"}, %{"type" => ["object", "null"]}] do
        assert_raise ArgumentError, ~r/inputSchema root must have type object/, fn ->
          @tool_map
          |> Map.put("inputSchema", invalid)
          |> Tool.from_map()
        end
      end
    end
  end
end
