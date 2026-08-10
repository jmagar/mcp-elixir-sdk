defmodule MCP.Protocol.ToolRoutingTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.ToolRouting

  @descriptor %{header: "Region", path: ["route", "region"], type: "string"}

  test "nested routing paths reject non-map intermediate values without raising" do
    for intermediate <- ["not-an-object", 7, []] do
      assert ToolRouting.argument_value(%{"route" => intermediate}, @descriptor) ==
               {:error, :invalid_argument_type}
    end
  end

  test "top-level non-map arguments return a typed error" do
    descriptor = %{header: "Region", path: ["region"], type: "string"}

    for arguments <- [nil, "scalar", []] do
      assert ToolRouting.argument_value(arguments, descriptor) ==
               {:error, :invalid_argument_type}
    end
  end

  test "annotations below array-typed nodes are forbidden" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "items" => %{
          "type" => "array",
          "properties" => %{
            "region" => %{"type" => "string", "x-mcp-header" => "Region"}
          }
        }
      }
    }

    assert ToolRouting.descriptors(schema) == {:error, :forbidden_annotation_location}
  end

  test "nested properties without an explicit object type remain valid" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "route" => %{
          "properties" => %{
            "region" => %{"type" => "string", "x-mcp-header" => "Region"}
          }
        }
      }
    }

    assert {:ok, [%{path: ["route", "region"]}]} = ToolRouting.descriptors(schema)
  end

  test "nested nullable object unions remain valid" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "route" => %{
          "type" => ["object", "null"],
          "properties" => %{
            "region" => %{"type" => "string", "x-mcp-header" => "Region"}
          }
        }
      }
    }

    assert {:ok, [%{path: ["route", "region"]}]} = ToolRouting.descriptors(schema)
  end

  test "nested object unions with non-null scalar branches are forbidden" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "route" => %{
          "type" => ["object", "string"],
          "properties" => %{
            "region" => %{"type" => "string", "x-mcp-header" => "Region"}
          }
        }
      }
    }

    assert ToolRouting.descriptors(schema) == {:error, :forbidden_annotation_location}
  end

  @tag timeout: 2_000
  test "compiles a large flat routing schema without quadratic blowup" do
    properties =
      Map.new(1..8_000, fn index ->
        {"field_#{index}", %{"type" => "string", "x-mcp-header" => "Field-#{index}"}}
      end)

    assert {:ok, descriptors} =
             ToolRouting.descriptors(%{"type" => "object", "properties" => properties})

    assert length(descriptors) == 8_000
  end
end
