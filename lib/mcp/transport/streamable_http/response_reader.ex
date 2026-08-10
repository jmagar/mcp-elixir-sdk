defmodule MCP.Transport.StreamableHTTP.ResponseReader do
  @moduledoc false

  alias MCP.Transport.StreamableHTTP.SecurityPolicy

  @spec request(keyword(), SecurityPolicy.t()) ::
          {:ok, Req.Response.t(), binary()}
          | {:stream, Req.Response.t()}
          | {:error, term()}
  def request(options, %SecurityPolicy{} = policy) when is_list(options) do
    stream? = Keyword.get(options, :stream, false)

    options =
      options
      |> Keyword.delete(:stream)
      |> Keyword.merge(
        redirect: false,
        retry: false,
        raw: true,
        compressed: false,
        connect_options: [timeout: policy.connect_timeout],
        receive_timeout: policy.receive_timeout,
        request_timeout: policy.request_timeout,
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
        with :ok <- validate_content_length(response, policy.max_response_bytes),
             {:ok, body} <-
               consume(response, policy.max_response_bytes, policy.receive_timeout) do
          {:ok, %{response | body: body}, body}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec consume(Req.Response.t(), pos_integer(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def consume(response, limit, receive_timeout)
      when is_integer(limit) and limit > 0 and
             (is_integer(receive_timeout) or receive_timeout == :infinity) do
    consume_messages(response, limit, receive_timeout, 0, [])
  end

  defp consume_messages(response, limit, receive_timeout, size, chunks) do
    receive do
      message ->
        case Req.parse_message(response, message) do
          {:ok, parsed} ->
            consume_chunks(response, parsed, limit, receive_timeout, size, chunks)

          {:error, reason} ->
            {:error, reason}

          :unknown ->
            consume_messages(response, limit, receive_timeout, size, chunks)
        end
    after
      receive_timeout ->
        _ = Req.cancel_async_response(response)
        {:error, :receive_timeout}
    end
  end

  defp consume_chunks(response, parsed, limit, receive_timeout, size, chunks) do
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
        consume_messages(response, limit, receive_timeout, next_size, next_chunks)

      {:done, final_chunks} ->
        {:ok, final_chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, reason} ->
        {:error, reason}
    end
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
    case URI.parse(location) do
      %URI{} = uri -> URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})
      _other -> nil
    end
  end
end
