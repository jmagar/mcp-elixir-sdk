defmodule MCP.Protocol.Messages.SkillsTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Messages.Skills.{GetParams, GetResult, ListParams, ListResult}

  @digest "sha256:" <> String.duplicate("b", 64)
  @skill %{
    "uri" => "skill://demo/SKILL.md",
    "frontmatter" => %{"name" => "demo", "description" => "Demo", "license" => "MIT"},
    "resources" => [
      %{"uri" => "skill://demo/SKILL.md", "digest" => @digest, "size" => 42}
    ]
  }

  test "list params round-trip cursor and metadata" do
    map = %{"cursor" => "next", "_meta" => %{"progressToken" => 7}}
    assert {:ok, params} = ListParams.decode(map)
    assert ListParams.to_map(params) == map
  end

  test "get params round-trip an unlisted skill URI" do
    map = %{"uri" => "skill://demo/SKILL.md", "_meta" => %{"request" => "direct"}}
    assert {:ok, params} = GetParams.decode(map)
    assert GetParams.to_map(params) == map
  end

  test "list result preserves envelope and lossless entries" do
    map = %{
      "resultType" => "complete",
      "skills" => [@skill],
      "nextCursor" => "page-2",
      "ttlMs" => 100,
      "cacheScope" => "private",
      "_meta" => %{"com.example/page" => 1}
    }

    assert {:ok, result} = ListResult.decode(map)
    assert ListResult.to_map(result) == map
    assert Jason.decode!(Jason.encode!(result)) == map
  end

  test "list result permits empty and partial pages but rejects duplicate identity URIs" do
    assert {:ok, %ListResult{skills: []}} = ListResult.decode(%{"skills" => []})

    assert {:error, :duplicate_skill_uri} =
             ListResult.decode(%{"skills" => [@skill, @skill]})
  end

  test "get result is the same complete skill-entry shape without list caching assumptions" do
    map = %{"resultType" => "complete", "skill" => @skill, "_meta" => %{"snapshot" => 1}}
    assert {:ok, result} = GetResult.decode(map)
    assert GetResult.to_map(result) == map
  end

  test "rejects malformed envelopes deterministically" do
    assert {:error, :invalid_skills_list_params} = ListParams.decode(%{"cursor" => 7})
    assert {:error, :invalid_skills_get_params} = GetParams.decode(%{"uri" => 7})

    assert {:error, :invalid_skills_list_result} =
             ListResult.decode(%{"skills" => [], "cacheScope" => "shared"})

    assert {:error, :invalid_skills_get_result} =
             GetResult.decode(%{"skill" => @skill, "resultType" => "input_required"})
  end
end
