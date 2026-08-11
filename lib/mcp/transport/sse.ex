defmodule MCP.Transport.SSE do
  @moduledoc """
  Server-Sent Events (SSE) encoding and decoding utilities.

  Used by the Streamable HTTP transport for streaming JSON-RPC messages
  over SSE connections.

  ## SSE Format

  SSE events consist of field lines separated by newlines, with events
  separated by blank lines:

      event: message
      id: 1
      data: {"jsonrpc":"2.0",...}

  Fields:
    * `event:` — event type (default: "message")
    * `id:` — event ID for resumability
    * `data:` — event payload (JSON-RPC message)
    * `retry:` — reconnection interval in milliseconds
  """

  @type event :: %{
          optional(:event) => String.t(),
          optional(:id) => String.t(),
          optional(:data) => String.t(),
          optional(:retry) => non_neg_integer()
        }

  @type parser :: %{buffer: binary(), max_event_bytes: pos_integer()}

  @event_delimiters ["\r\n\r\n", "\n\n"]
  @event_delimiter_prefixes ["\r", "\r\n", "\r\n\r", "\n"]

  @doc """
  Encodes an SSE event map into a string suitable for streaming.

  ## Examples

      iex> MCP.Transport.SSE.encode_event(%{event: "message", data: ~s({"jsonrpc":"2.0"})})
      "event: message\\ndata: {\\"jsonrpc\\":\\"2.0\\"}\\n\\n"

      iex> MCP.Transport.SSE.encode_event(%{id: "42", data: "hello"})
      "id: 42\\ndata: hello\\n\\n"
  """
  @spec encode_event(event()) :: String.t()
  def encode_event(event) when is_map(event) do
    lines =
      []
      |> maybe_add_field("event", Map.get(event, :event))
      |> maybe_add_field("id", Map.get(event, :id))
      |> maybe_add_field("retry", encode_retry(Map.get(event, :retry)))
      |> add_data_field(Map.get(event, :data))

    IO.iodata_to_binary([Enum.join(lines, "\n"), "\n\n"])
  end

  @doc """
  Encodes a JSON-RPC message as an SSE event.

  Convenience function that JSON-encodes the message and wraps it in
  an SSE event with the "message" event type.

  ## Options

    * `:id` — event ID for resumability
    * `:event` — event type (default: "message")
  """
  @spec encode_message(map(), keyword()) :: String.t()
  def encode_message(message, opts \\ []) when is_map(message) do
    event = %{
      event: Keyword.get(opts, :event, "message"),
      data: Jason.encode!(message)
    }

    event =
      case Keyword.get(opts, :id) do
        nil -> event
        id -> Map.put(event, :id, to_string(id))
      end

    encode_event(event)
  end

  @doc """
  Decodes an SSE event string into an event map.

  Parses the standard SSE fields (event, id, data, retry) from the
  event text. Multiple `data:` lines are joined with newlines.

  Returns `{:ok, event}` or `{:error, reason}`.
  """
  @spec decode_event(String.t()) :: {:ok, event()} | {:error, term()}
  def decode_event(text) when is_binary(text) do
    lines = String.split(text, "\n")

    event =
      Enum.reduce(lines, %{}, fn line, acc ->
        parse_field(line, acc)
      end)
      |> finalize_data()

    if map_size(event) == 0 do
      {:error, :empty_event}
    else
      {:ok, event}
    end
  end

  @doc """
  Creates a new stream parser for incrementally parsing SSE events
  from chunked data.

  Returns an initial parser state. Feed data to it using `feed/2`.

  ## Example

      parser = MCP.Transport.SSE.new_parser()
      {events, parser} = MCP.Transport.SSE.feed(parser, chunk1)
      {events, parser} = MCP.Transport.SSE.feed(parser, chunk2)
  """
  @spec new_parser(keyword()) :: binary() | parser()
  def new_parser(opts \\ [])
  def new_parser([]), do: ""

  def new_parser(opts) when is_list(opts) do
    max_event_bytes = Keyword.fetch!(opts, :max_event_bytes)

    if is_integer(max_event_bytes) and max_event_bytes > 0 do
      %{buffer: "", max_event_bytes: max_event_bytes}
    else
      raise ArgumentError, ":max_event_bytes must be a positive integer"
    end
  end

  @doc """
  Feeds data to a stream parser and returns any complete events.

  Returns `{events, new_parser_state}` where events is a list of
  decoded event maps.
  """
  @spec feed(binary(), binary()) :: {[event()], binary()}
  def feed(buffer, data) when is_binary(buffer) and is_binary(data) do
    combined = buffer <> data
    extract_events(combined, [])
  end

  @spec feed(parser(), binary()) ::
          {:ok, [event()], parser()} | {:error, :event_too_large}
  def feed(%{buffer: buffer, max_event_bytes: limit} = parser, data) when is_binary(data) do
    combined = buffer <> data

    case extract_bounded_events(combined, [], limit) do
      {:ok, events, remainder} -> {:ok, events, %{parser | buffer: remainder}}
      {:error, :event_too_large} = error -> error
    end
  end

  # --- Private helpers ---

  defp maybe_add_field(lines, _field, nil), do: lines
  defp maybe_add_field(lines, _field, ""), do: lines
  defp maybe_add_field(lines, field, value), do: lines ++ ["#{field}: #{value}"]

  defp encode_retry(nil), do: nil
  defp encode_retry(ms) when is_integer(ms), do: Integer.to_string(ms)

  defp add_data_field(lines, nil), do: lines ++ ["data: "]
  defp add_data_field(lines, ""), do: lines ++ ["data: "]

  defp add_data_field(lines, data) do
    # Multi-line data is split into multiple `data:` lines
    data_lines =
      data
      |> String.split("\n")
      |> Enum.map(fn line -> "data: #{line}" end)

    lines ++ data_lines
  end

  defp parse_field(":" <> _rest, acc), do: acc
  defp parse_field("", acc), do: acc

  defp parse_field(line, acc) do
    case String.split(line, ": ", parts: 2) do
      [field, value] -> apply_field(field, String.trim(value), acc)
      [field_with_colon] -> maybe_parse_no_space(field_with_colon, acc)
    end
  end

  defp maybe_parse_no_space(text, acc) do
    case String.split(text, ":", parts: 2) do
      [field, value] -> apply_field(field, String.trim(value), acc)
      _ -> acc
    end
  end

  defp apply_field("event", value, acc), do: Map.put(acc, :event, value)
  defp apply_field("id", value, acc), do: Map.put(acc, :id, value)

  defp apply_field("retry", value, acc) do
    case Integer.parse(value) do
      {ms, ""} -> Map.put(acc, :retry, ms)
      _ -> acc
    end
  end

  defp apply_field("data", value, acc) do
    Map.update(acc, :data_lines, [value], &[value | &1])
  end

  defp apply_field(_unknown, _value, acc), do: acc

  defp finalize_data(%{data_lines: lines} = event) do
    event
    |> Map.delete(:data_lines)
    |> Map.put(:data, lines |> Enum.reverse() |> Enum.join("\n"))
  end

  defp finalize_data(event), do: event

  defp extract_events(buffer, events) do
    case split_event(buffer) do
      {:ok, event_text, rest} ->
        case decode_event(event_text) do
          {:ok, event} ->
            extract_events(rest, [event | events])

          {:error, _} ->
            extract_events(rest, events)
        end

      :incomplete ->
        {Enum.reverse(events), buffer}
    end
  end

  defp extract_bounded_events(buffer, events, limit) do
    case match_event_delimiter(buffer) do
      {position, _size} when position > limit ->
        {:error, :event_too_large}

      {_position, _size} = match ->
        {:ok, event_text, rest} = split_event(buffer, match)

        events =
          case decode_event(event_text) do
            {:ok, event} -> [event | events]
            {:error, _reason} -> events
          end

        extract_bounded_events(rest, events, limit)

      :nomatch ->
        if byte_size(buffer) > limit and not pending_delimiter_prefix?(buffer, limit) do
          {:error, :event_too_large}
        else
          {:ok, Enum.reverse(events), buffer}
        end
    end
  end

  defp split_event(buffer), do: split_event(buffer, match_event_delimiter(buffer))

  defp split_event(_buffer, :nomatch), do: :incomplete

  # `:binary.match/2` returns {Position, Length}: the position is the byte size
  # of the event text, and the length is the delimiter's own size.
  defp split_event(buffer, {position, size}) do
    <<event_text::binary-size(^position), _delimiter::binary-size(^size), rest::binary>> = buffer
    {:ok, event_text, rest}
  end

  # Events are separated by a blank line. Compliant producers may terminate
  # lines with either LF or CRLF, so both delimiters must be recognised — and
  # the delimiter length preserved — or a CRLF stream never yields an event.
  defp match_event_delimiter(buffer), do: :binary.match(buffer, @event_delimiters)

  defp pending_delimiter_prefix?(buffer, limit) do
    buffer_size = byte_size(buffer)

    Enum.any?(@event_delimiter_prefixes, fn prefix ->
      prefix_size = byte_size(prefix)
      event_size = buffer_size - prefix_size

      event_size >= 0 and event_size <= limit and
        binary_part(buffer, event_size, prefix_size) == prefix
    end)
  end
end
