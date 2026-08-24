defmodule MCP.Protocol.OpenTypeAuditTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Error

  alias MCP.Protocol.Messages.{
    Completion,
    Discover,
    Elicitation,
    Prompts,
    Resources,
    Roots,
    Sampling,
    Skills,
    Tools
  }

  alias MCP.Protocol.Messages.Subscriptions.ListenResult

  @vendor_value %{"nested" => [false, nil, 0, ""]}
  @digest "sha256:" <> String.duplicate("a", 64)

  test "every typed core Result boundary preserves unknown JSON members" do
    cases = [
      {Tools.ListResult, %{"tools" => [], "vendor" => @vendor_value}, "tools"},
      {Resources.ListResult, %{"resources" => [], "vendor" => @vendor_value}, "resources"},
      {Resources.ReadResult, %{"contents" => [], "vendor" => @vendor_value}, "contents"},
      {Resources.ListTemplatesResult, %{"resourceTemplates" => [], "vendor" => @vendor_value},
       "resourceTemplates"},
      {Prompts.ListResult, %{"prompts" => [], "vendor" => @vendor_value}, "prompts"},
      {Prompts.GetResult, %{"messages" => [], "vendor" => @vendor_value}, "messages"},
      {Elicitation.Result, %{"action" => "decline", "vendor" => @vendor_value}, "action"},
      {Roots.ListResult, %{"roots" => [], "vendor" => @vendor_value}, "roots"},
      {Sampling.CreateMessageResult,
       %{
         "role" => "assistant",
         "content" => %{"type" => "text", "text" => "done"},
         "model" => "test-model",
         "vendor" => @vendor_value
       }, "model"},
      {Completion.Result,
       %{
         "completion" => %{"values" => [], "hasMore" => false, "total" => 0},
         "vendor" => @vendor_value
       }, "completion"}
    ]

    for {module, wire, known_key} <- cases do
      decoded = module.from_map(wire)

      assert decoded.extra == %{"vendor" => @vendor_value}
      assert Jason.decode!(Jason.encode!(decoded)) == wire

      assert_raise ArgumentError, ~r/collides with #{known_key}/, fn ->
        decoded
        |> Map.put(:extra, %{known_key => "ambiguous"})
        |> Jason.encode!()
      end
    end
  end

  test "extension Result and Error boundaries share the full open-object contract" do
    skill = %{
      "uri" => "https://skills.example/demo/SKILL.md",
      "frontmatter" => %{"name" => "demo", "description" => "demo"},
      "resources" => [
        %{
          "uri" => "https://skills.example/demo/SKILL.md",
          "digest" => @digest,
          "size" => 1
        }
      ]
    }

    cases = [
      {fn map -> {:ok, Discover.Result.from_map(map)} end, &Discover.Result.to_map/1,
       %{
         "supportedVersions" => ["2026-07-28"],
         "capabilities" => %{},
         "resultType" => "complete",
         "ttlMs" => 0,
         "cacheScope" => "public"
       }, "capabilities"},
      {fn map -> {:ok, Error.from_map(map)} end, &Jason.decode!(Jason.encode!(&1)),
       %{"code" => -32_600, "message" => "Invalid request", "data" => nil}, "code"},
      {&Skills.ListResult.decode/1, &Jason.decode!(Jason.encode!(&1)),
       %{"skills" => [skill], "resultType" => "complete"}, "skills"},
      {&Skills.GetResult.decode/1, &Jason.decode!(Jason.encode!(&1)),
       %{"skill" => skill, "resultType" => "complete"}, "skill"},
      {&Resources.DirectoryReadResult.decode/1, &Jason.decode!(Jason.encode!(&1)),
       %{
         "resources" => [%{"uri" => "skill://demo/a", "name" => "a"}],
         "resultType" => "complete"
       }, "resources"}
    ]

    for {decoder, encoder, base_wire, known_key} <- cases do
      wire = Map.put(base_wire, "vendor", @vendor_value)
      assert {:ok, decoded} = decoder.(wire)
      assert decoded.extra == %{"vendor" => @vendor_value}
      assert encoder.(decoded) == wire

      assert_raise ArgumentError, ~r/collides with #{known_key}/, fn ->
        decoded |> Map.put(:extra, %{known_key => "ambiguous"}) |> encoder.()
      end

      assert_raise ArgumentError, ~r/field names must be strings/, fn ->
        decoded |> Map.put(:extra, %{1 => "invalid"}) |> encoder.()
      end

      assert_raise ArgumentError, ~r/must contain a JSON value/, fn ->
        decoded |> Map.put(:extra, %{"vendor" => self()}) |> encoder.()
      end
    end
  end

  test "subscription Result boundary preserves unknown JSON members" do
    wire = %{
      "resultType" => "complete",
      "_meta" => %{"io.modelcontextprotocol/subscriptionId" => "sub-1"},
      "vendor" => @vendor_value
    }

    result = ListenResult.from_map(wire)
    assert result.extra == %{"vendor" => @vendor_value}
    assert Jason.decode!(Jason.encode!(result)) == wire

    assert_raise ArgumentError, ~r/collides with resultType/, fn ->
      Jason.encode!(%{result | extra: %{"resultType" => "ambiguous"}})
    end
  end
end
