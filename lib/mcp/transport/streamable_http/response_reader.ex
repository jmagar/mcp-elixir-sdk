defmodule MCP.Transport.StreamableHTTP.ResponseReader do
  @moduledoc false

  alias MCP.Transport.StreamableHTTP.SecurityPolicy

  @spec request(keyword(), SecurityPolicy.t()) ::
          {:ok, Req.Response.t(), binary()}
          | {:stream, Req.Response.t()}
          | {:error, term()}
  def request(options, %SecurityPolicy{} = policy) when is_list(options) do
    stream? = Keyword.get(options, :stream, false)
    deadline = deadline(policy.request_timeout)

    options =
      options
      |> Keyword.delete(:stream)
      |> Keyword.merge(
        redirect: false,
        retry: false,
        raw: true,
        compressed: false,
        connect_options: [timeout: SecurityPolicy.connection_timeout(policy)],
        # `into: :self` returns as soon as the response headers arrive. Req 0.5
        # has no `:request_timeout` option, so this cross-version adapter bounds
        # that phase by clamping `:receive_timeout` to the overall budget. The
        # reader below enforces the total deadline while consuming the body.
        receive_timeout: min_timeout(policy.receive_timeout, policy.request_timeout),
        into: :self
      )

    case Req.request(options) do
      {:ok, %Req.Response{status: status} = response} when status in 300..399 ->
        _ = Req.cancel_async_response(response)

        {:error,
         {:redirect_rejected, status, sanitized_location(header(response.headers, "location"))}}

      {:ok, %Req.Response{} = response} when stream? ->
        {:stream, response}

      {:ok, %Req.Response{} = response} ->
        # Compression is disabled, so the wire and decoded bodies are the same
        # byte stream. Enforce the stricter configured boundary now rather than
        # accepting a decoded-limit option that has no effect.
        response_limit = SecurityPolicy.response_limit(policy)

        with :ok <- validate_content_length(response, response_limit),
             {:ok, body} <-
               consume_messages(
                 response,
                 response_limit,
                 policy.receive_timeout,
                 deadline,
                 0,
                 []
               ) do
          {:ok, %{response | body: body}, body}
        end

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :request_timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec consume(Req.Response.t(), pos_integer(), timeout(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  @doc """
  Consumes an asynchronous Req response from the calling process mailbox.

  Call this from an isolated request process: messages that do not belong to
  the response are ignored while the response is being drained.

  `receive_timeout` bounds the gap between chunks; `request_timeout` bounds the
  whole drain. Without the latter, a peer that drips one byte inside every
  receive window keeps the drain alive until `limit` bytes have arrived.
  """
  def consume(response, limit, receive_timeout, request_timeout \\ :infinity)
      when is_integer(limit) and limit > 0 and
             (is_integer(receive_timeout) or receive_timeout == :infinity) and
             (is_integer(request_timeout) or request_timeout == :infinity) do
    consume_messages(response, limit, receive_timeout, deadline(request_timeout), 0, [])
  end

  defp consume_messages(response, limit, receive_timeout, deadline, size, chunks) do
    timeout = next_timeout(receive_timeout, deadline)

    if timeout == 0 do
      _ = Req.cancel_async_response(response)
      {:error, :request_timeout}
    else
      receive do
        message ->
          case Req.parse_message(response, message) do
            {:ok, parsed} ->
              consume_chunks(response, parsed, limit, receive_timeout, deadline, size, chunks)

            {:error, reason} ->
              _ = Req.cancel_async_response(response)
              {:error, reason}

            :unknown ->
              consume_messages(response, limit, receive_timeout, deadline, size, chunks)
          end
      after
        timeout ->
          _ = Req.cancel_async_response(response)
          {:error, timeout_reason(receive_timeout, deadline)}
      end
    end
  end

  defp consume_chunks(response, parsed, limit, receive_timeout, deadline, size, chunks) do
    Enum.reduce_while(parsed, {:continue, size, chunks}, fn
      {:data, chunk}, {:continue, current_size, current_chunks} ->
        next_size = current_size + byte_size(chunk)

        if next_size > limit do
          _ = Req.cancel_async_response(response)
          {:halt, {:error, {:response_too_large, limit}}}
        else
          {:cont, {:continue, next_size, [chunk | current_chunks]}}
        end

      :done, {:continue, _current_size, current_chunks} ->
        {:halt, {:done, current_chunks}}

      {:trailers, _trailers}, accumulator ->
        {:cont, accumulator}
    end)
    |> case do
      {:continue, next_size, next_chunks} ->
        consume_messages(response, limit, receive_timeout, deadline, next_size, next_chunks)

      {:done, final_chunks} ->
        {:ok, final_chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp min_timeout(:infinity, other), do: other
  defp min_timeout(timeout, :infinity), do: timeout
  defp min_timeout(timeout, other), do: min(timeout, other)

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp next_timeout(:infinity, :infinity), do: :infinity
  defp next_timeout(timeout, :infinity), do: timeout

  defp next_timeout(:infinity, deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp next_timeout(timeout, deadline),
    do: min(timeout, max(deadline - System.monotonic_time(:millisecond), 0))

  defp timeout_reason(_receive_timeout, :infinity), do: :receive_timeout
  defp timeout_reason(:infinity, _deadline), do: :request_timeout

  defp timeout_reason(receive_timeout, deadline) do
    if deadline - System.monotonic_time(:millisecond) <= receive_timeout,
      do: :request_timeout,
      else: :receive_timeout
  end

  defp validate_content_length(response, limit) do
    case header(response.headers, "content-length") do
      nil ->
        :ok

      value ->
        case Integer.parse(value) do
          {length, ""} when length <= limit -> :ok
          {length, ""} when length > limit -> cancel_too_large(response, limit)
          _invalid -> :ok
        end
    end
  end

  defp cancel_too_large(response, limit) do
    _ = Req.cancel_async_response(response)
    {:error, {:response_too_large, limit}}
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, values} ->
      if String.downcase(key) == name do
        values |> List.wrap() |> List.first()
      end
    end)
  end

  defp sanitized_location(nil), do: nil

  defp sanitized_location(location) do
    uri = URI.parse(location)
    URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})
  end
end
