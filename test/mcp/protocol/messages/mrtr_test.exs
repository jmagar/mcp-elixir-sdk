defmodule MCP.Protocol.Messages.MRTRTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Messages.MRTR

  test "extracts stateful and ephemeral continuations" do
    assert MRTR.continuation_from_params(%{
             "requestState" => "opaque",
             "inputResponses" => %{"answer" => %{}}
           }) == %{request_state: "opaque", responses: %{"answer" => %{}}}

    assert MRTR.continuation_from_params(%{"inputResponses" => %{"answer" => %{}}}) == %{
             request_state: nil,
             responses: %{"answer" => %{}}
           }
  end

  test "does not treat an ordinary request as a continuation" do
    assert MRTR.continuation_from_params(%{"name" => "example"}) == nil
    assert MRTR.continuation_from_params(nil) == nil
  end

  test "rejects malformed continuation wire types" do
    assert MRTR.continuation_from_params(%{"requestState" => 42}) ==
             {:error, :request_state_must_be_a_string}

    assert MRTR.continuation_from_params(%{"inputResponses" => []}) ==
             {:error, :input_responses_must_be_an_object}

    assert MRTR.continuation_from_params(%{"requestState" => nil}) ==
             {:error, :request_state_must_be_a_string}
  end
end
