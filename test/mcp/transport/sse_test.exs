defmodule MCP.Transport.SSETest do
  use ExUnit.Case, async: true

  alias MCP.Transport.SSE

  describe "encode_event/1" do
    test "encodes event with all fields" do
      event = %{event: "message", id: "42", data: ~s({"key":"value"}), retry: 3000}
      result = SSE.encode_event(event)

      assert result =~ "event: message\n"
      assert result =~ "id: 42\n"
      assert result =~ "retry: 3000\n"
      assert result =~ ~s(data: {"key":"value"}\n)
      assert String.ends_with?(result, "\n\n")
    end

    test "encodes event with only data" do
      result = SSE.encode_event(%{data: "hello"})
      assert result == "data: hello\n\n"
    end

    test "encodes event with event type and data" do
      result = SSE.encode_event(%{event: "message", data: "hello"})
      assert result == "event: message\ndata: hello\n\n"
    end

    test "encodes event with empty data" do
      result = SSE.encode_event(%{id: "1"})
      assert result =~ "id: 1\n"
      assert result =~ "data: \n"
    end

    test "encodes multi-line data as multiple data fields" do
      result = SSE.encode_event(%{data: "line1\nline2\nline3"})
      assert result == "data: line1\ndata: line2\ndata: line3\n\n"
    end
  end

  describe "encode_message/2" do
    test "encodes a JSON-RPC message as SSE event" do
      message = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => []}}
      result = SSE.encode_message(message)

      assert result =~ "event: message\n"
      assert result =~ "data: "

      # Extract the data line and verify it's valid JSON
      [data_line] =
        result
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data: "))

      json = String.trim_leading(data_line, "data: ")
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
    end

    test "includes event ID when provided" do
      message = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
      result = SSE.encode_message(message, id: "evt-42")

      assert result =~ "id: evt-42\n"
    end

    test "uses custom event type" do
      message = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
      result = SSE.encode_message(message, event: "response")

      assert result =~ "event: response\n"
    end
  end

  describe "decode_event/1" do
    test "decodes event with all fields" do
      text = "event: message\nid: 42\ndata: hello\nretry: 3000"
      assert {:ok, event} = SSE.decode_event(text)

      assert event.event == "message"
      assert event.id == "42"
      assert event.data == "hello"
      assert event.retry == 3000
    end

    test "decodes event with only data" do
      assert {:ok, event} = SSE.decode_event("data: hello world")
      assert event.data == "hello world"
      refute Map.has_key?(event, :event)
      refute Map.has_key?(event, :id)
    end

    test "decodes event with JSON data" do
      json = ~s({"jsonrpc":"2.0","id":1})
      assert {:ok, event} = SSE.decode_event("data: #{json}")
      assert event.data == json
    end

    test "joins multiple data lines with newlines" do
      text = "data: line1\ndata: line2\ndata: line3"
      assert {:ok, event} = SSE.decode_event(text)
      assert event.data == "line1\nline2\nline3"
    end

    test "ignores comment lines" do
      text = ": this is a comment\ndata: hello"
      assert {:ok, event} = SSE.decode_event(text)
      assert event.data == "hello"
    end

    test "ignores unknown fields" do
      text = "custom: value\ndata: hello"
      assert {:ok, event} = SSE.decode_event(text)
      assert event.data == "hello"
    end

    test "returns error for empty event" do
      assert {:error, :empty_event} = SSE.decode_event("")
    end

    test "handles fields without space after colon" do
      text = "data:hello"
      assert {:ok, event} = SSE.decode_event(text)
      assert event.data == "hello"
    end
  end

  describe "stream parser" do
    test "rejects an incomplete event before its buffer exceeds the configured limit" do
      parser = SSE.new_parser(max_event_bytes: 8)

      assert {:ok, [], parser} = SSE.feed(parser, "data: 1")
      assert {:error, :event_too_large} = SSE.feed(parser, "23")
    end

    test "rejects a complete event larger than the configured limit" do
      parser = SSE.new_parser(max_event_bytes: 8)
      assert {:error, :event_too_large} = SSE.feed(parser, "data: 123\n\n")
    end

    test "accepts CRLF-terminated events within the configured limit" do
      parser = SSE.new_parser(max_event_bytes: 64)
      body = "event: message\r\ndata: one\r\n\r\nevent: message\r\ndata: two\r\n\r\n"

      assert {:ok, events, parser} = SSE.feed(parser, body)
      assert Enum.map(events, & &1.data) == ["one", "two"]
      assert parser.buffer == ""
    end

    test "bounds a CRLF-terminated event by its own length, not the whole buffer" do
      parser = SSE.new_parser(max_event_bytes: 8)
      assert {:error, :event_too_large} = SSE.feed(parser, "data: 123456789\r\n\r\n")
    end

    test "reassembles a CRLF delimiter split across chunks" do
      parser = SSE.new_parser(max_event_bytes: 64)

      assert {:ok, [], parser} = SSE.feed(parser, "data: split\r\n")
      assert {:ok, [event], _parser} = SSE.feed(parser, "\r\ndata: next")
      assert event.data == "split"
    end

    test "the unbounded parser also splits CRLF-terminated events" do
      parser = SSE.new_parser()

      {events, _parser} = SSE.feed(parser, "event: message\r\ndata: hello\r\n\r\n")
      assert [%{event: "message", data: "hello"}] = events
    end

    test "parses complete events" do
      parser = SSE.new_parser()
      data = "event: message\ndata: hello\n\nevent: message\ndata: world\n\n"

      {events, _parser} = SSE.feed(parser, data)
      assert length(events) == 2
      assert Enum.at(events, 0).data == "hello"
      assert Enum.at(events, 1).data == "world"
    end

    test "buffers incomplete events" do
      parser = SSE.new_parser()

      # First chunk — incomplete event
      {events1, parser} = SSE.feed(parser, "event: message\ndata: hel")
      assert events1 == []

      # Second chunk — completes the event
      {events2, _parser} = SSE.feed(parser, "lo\n\n")
      assert length(events2) == 1
      assert Enum.at(events2, 0).data == "hello"
    end

    test "handles multiple chunks" do
      parser = SSE.new_parser()

      {events1, parser} = SSE.feed(parser, "data: one\n\ndata: tw")
      assert length(events1) == 1
      assert Enum.at(events1, 0).data == "one"

      {events2, parser} = SSE.feed(parser, "o\n\ndata: thr")
      assert length(events2) == 1
      assert Enum.at(events2, 0).data == "two"

      {events3, _parser} = SSE.feed(parser, "ee\n\n")
      assert length(events3) == 1
      assert Enum.at(events3, 0).data == "three"
    end

    test "round-trip encode then decode" do
      message = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => []}}
      encoded = SSE.encode_message(message, id: "evt-1")

      parser = SSE.new_parser()
      {events, _parser} = SSE.feed(parser, encoded)
      assert length(events) == 1
      event = Enum.at(events, 0)
      assert event.event == "message"
      assert event.id == "evt-1"

      assert {:ok, decoded} = Jason.decode(event.data)
      assert decoded == message
    end
  end
end
