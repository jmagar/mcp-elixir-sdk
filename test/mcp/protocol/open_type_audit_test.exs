defmodule MCP.Protocol.OpenTypeAuditTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Messages.{Completion, Prompts, Resources, Tools}
  alias MCP.Protocol.Messages.Subscriptions.ListenResult

  @vendor_value %{"nested" => [false, nil, 0, ""]}

  test "every typed core Result boundary preserves unknown JSON members" do
    cases = [
      {Tools.ListResult, %{"tools" => [], "vendor" => @vendor_value}, "tools"},
      {Resources.ListResult, %{"resources" => [], "vendor" => @vendor_value}, "resources"},
      {Resources.ReadResult, %{"contents" => [], "vendor" => @vendor_value}, "contents"},
      {Resources.ListTemplatesResult, %{"resourceTemplates" => [], "vendor" => @vendor_value},
       "resourceTemplates"},
      {Prompts.ListResult, %{"prompts" => [], "vendor" => @vendor_value}, "prompts"},
      {Prompts.GetResult, %{"messages" => [], "vendor" => @vendor_value}, "messages"},
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
