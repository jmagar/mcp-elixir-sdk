defmodule MCP.Protocol.Messages.ResourcesDirectoryTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Messages.Resources.{DirectoryReadParams, DirectoryReadResult}

  test "directory params round-trip URI, cursor, and metadata" do
    map = %{"uri" => "skill://demo/templates", "cursor" => "next", "_meta" => %{"page" => 2}}
    assert {:ok, params} = DirectoryReadParams.decode(map)
    assert DirectoryReadParams.to_map(params) == map
  end

  test "directory params reject explicit null and unknown members" do
    uri = "skill://demo/templates"

    assert {:error, :invalid_directory_read_params} =
             DirectoryReadParams.decode(%{"uri" => uri, "cursor" => nil})

    assert {:error, :invalid_directory_read_params} =
             DirectoryReadParams.decode(%{"uri" => uri, "future" => true})

    assert {:error, :invalid_directory_read_params} = DirectoryReadParams.decode(%{"uri" => ""})
  end

  test "directory result round-trips direct children and complete envelope" do
    map = %{
      "resultType" => "complete",
      "resources" => [
        %{
          "uri" => "skill://demo/templates/a.md",
          "name" => "a.md",
          "mimeType" => "text/markdown"
        },
        %{
          "uri" => "skill://demo/templates/nested",
          "name" => "nested",
          "mimeType" => "inode/directory"
        }
      ],
      "nextCursor" => "next",
      "_meta" => %{"live" => true},
      "vendor" => %{"nested" => [false, nil, 0]}
    }

    assert {:ok, result} = DirectoryReadResult.decode(map)
    assert Jason.decode!(Jason.encode!(result)) == map
  end

  test "allows an empty directory and rejects malformed entries and envelopes" do
    assert {:ok, %DirectoryReadResult{resources: []}} =
             DirectoryReadResult.decode(%{"resources" => []})

    assert {:error, :invalid_directory_read_result} =
             DirectoryReadResult.decode(%{"resources" => [%{"uri" => "skill://demo/a"}]})

    assert {:error, :invalid_directory_read_result} =
             DirectoryReadResult.decode(%{"resources" => [], "nextCursor" => 0})

    for resource <- [
          %{"uri" => 42, "name" => "bad"},
          %{"uri" => "skill://demo/a", "name" => []},
          %{"uri" => "skill://demo/a", "name" => "a", "size" => -1},
          %{"uri" => "skill://demo/a", "name" => "a", "_meta" => []},
          %{"uri" => "skill://demo/a", "name" => "a", "annotations" => %{"audience" => 7}},
          %{"uri" => "skill://demo/a", "name" => "a", "icons" => [%{"src" => 5}]}
        ] do
      assert {:error, :invalid_directory_read_result} =
               DirectoryReadResult.decode(%{"resources" => [resource]})
    end
  end
end
