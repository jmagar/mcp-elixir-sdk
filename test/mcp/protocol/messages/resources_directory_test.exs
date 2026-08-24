defmodule MCP.Protocol.Messages.ResourcesDirectoryTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Messages.Resources.{DirectoryReadParams, DirectoryReadResult}

  test "directory params round-trip URI, cursor, and metadata" do
    map = %{"uri" => "skill://demo/templates", "cursor" => "next", "_meta" => %{"page" => 2}}
    assert {:ok, params} = DirectoryReadParams.decode(map)
    assert DirectoryReadParams.to_map(params) == map
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
      "_meta" => %{"live" => true}
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
             DirectoryReadResult.decode(%{"resources" => [], "ttlMs" => 0})
  end
end
