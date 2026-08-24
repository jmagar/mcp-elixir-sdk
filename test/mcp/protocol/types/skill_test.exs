defmodule MCP.Protocol.Types.SkillTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Types.{Skill, SkillResource}

  @digest "sha256:" <> String.duplicate("a", 64)

  defp resource(uri, size \\ 1), do: %{"uri" => uri, "digest" => @digest, "size" => size}

  defp skill(uri \\ "skill://demo/SKILL.md", resources \\ nil) do
    %{
      "uri" => uri,
      "frontmatter" => %{
        "name" => "demo",
        "description" => "A demo",
        "future" => %{"nested" => [1, true, nil]}
      },
      "resources" => resources || [resource(uri)],
      "_meta" => %{"com.example/source" => "fixture"}
    }
  end

  test "round-trips top-level and nested skill URIs losslessly" do
    for map <- [
          skill(),
          skill("skill://acme/team/demo/SKILL.md", [
            resource("skill://acme/team/demo/SKILL.md"),
            resource("skill://acme/team/demo/references/GUIDE.md")
          ])
        ] do
      assert {:ok, decoded} = Skill.decode_and_validate(map)
      assert Skill.to_map(decoded) == map
      assert Jason.decode!(Jason.encode!(decoded)) == map
    end
  end

  test "preserves the explicit dynamic marker" do
    map = skill("skill://demo/SKILL.md", "dynamic")
    assert {:ok, %Skill{resources: :dynamic} = decoded} = Skill.decode_and_validate(map)
    assert Skill.to_map(decoded) == map
    assert Skill.manifest_size(decoded) == :dynamic
  end

  test "validates digest spelling and nonnegative integer sizes" do
    assert {:ok, %SkillResource{}} = SkillResource.decode(resource("skill://demo/SKILL.md", 0))

    for invalid <- [
          %{
            "uri" => "skill://demo/SKILL.md",
            "digest" => "sha256:" <> String.duplicate("A", 64),
            "size" => 1
          },
          %{"uri" => "skill://demo/SKILL.md", "digest" => @digest, "size" => -1},
          %{"uri" => "skill://demo/SKILL.md", "digest" => @digest, "size" => 1.0}
        ] do
      assert {:error, _} = SkillResource.decode(invalid)
    end
  end

  test "rejects missing, empty, and malformed manifests while preserving larger valid ones" do
    assert {:error, :invalid_skill} = Skill.decode(Map.delete(skill(), "resources"))
    assert {:error, :empty_skill_manifest} = Skill.decode(skill("skill://demo/SKILL.md", []))

    assert {:error, :invalid_skill_resources} =
             Skill.decode(skill("skill://demo/SKILL.md", "static"))

    too_many =
      [resource("skill://demo/SKILL.md") | Enum.map(1..512, &resource("skill://demo/#{&1}.txt"))]

    assert {:ok, decoded} = Skill.decode_and_validate(skill("skill://demo/SKILL.md", too_many))
    assert Skill.manifest_size(decoded).resources == 513

    assert {:ok, decoded} =
             Skill.decode_and_validate(
               skill("skill://demo/SKILL.md", [resource("skill://demo/SKILL.md", 16_777_217)])
             )

    assert Skill.manifest_size(decoded).bytes == 16_777_217
  end

  test "rejects traversal, URI ambiguity, aliases, and missing SKILL.md" do
    for uri <- [
          "skill://demo/../secret",
          "skill://demo/%2e%2e/secret",
          "skill://demo/%252e%252e/secret",
          "skill://demo/a%2fb",
          "skill://demo/a%5cb",
          "skill://demo/a\\b",
          "skill://demo/file?revision=1",
          "skill://demo/file#fragment",
          "skill://user@demo/file"
        ] do
      assert {:error, _} =
               Skill.decode_and_validate(
                 skill("skill://demo/SKILL.md", [resource("skill://demo/SKILL.md"), resource(uri)])
               )
    end

    aliases = [resource("skill://demo/SKILL.md"), resource("skill://demo/%53KILL.md")]

    assert {:error, :duplicate_skill_resource} =
             Skill.decode_and_validate(skill("skill://demo/SKILL.md", aliases))

    assert {:error, :missing_skill_md_resource} =
             Skill.decode_and_validate(
               skill("skill://demo/SKILL.md", [resource("skill://demo/other.md")])
             )
  end

  test "validate is total for externally constructed malformed structs" do
    assert {:error, :invalid_skill} = Skill.validate(%Skill{resources: nil})

    assert {:error, :invalid_skill_resources} =
             Skill.validate(%Skill{
               uri: "skill://demo/SKILL.md",
               frontmatter: %{"name" => "demo", "description" => "Demo"},
               resources: [%{"not" => "typed"}]
             })
  end

  test "requires frontmatter name and URI parent to agree" do
    assert {:error, :skill_name_uri_mismatch} =
             skill()
             |> put_in(["frontmatter", "name"], "other")
             |> Skill.decode_and_validate()
  end

  test "bounds and validates lossless frontmatter and metadata" do
    assert {:error, :skill_metadata_limit} =
             skill()
             |> put_in(["frontmatter", "future"], String.duplicate("x", 1_048_577))
             |> Skill.decode()

    assert {:error, :skill_metadata_limit} =
             skill()
             |> Map.put("_meta", %{atom_key: "not JSON"})
             |> Skill.decode()
  end
end
