defmodule MCP.Protocol do
  @moduledoc """
  JSON-RPC 2.0 encoding/decoding for MCP messages.
  """

  alias MCP.Protocol.Error
  alias MCP.Protocol.Messages.{Notification, Request, Response}

  @protocol_version "2026-07-28"
  @supported_versions ["2026-07-28", "2025-11-25"]
  @jsonrpc_version "2.0"

  @type json_value ::
          nil
          | boolean()
          | number()
          | String.t()
          | [json_value()]
          | %{required(String.t()) => json_value()}

  @doc """
  Returns the MCP protocol version this library targets.
  """
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @doc "Returns every supported MCP revision, newest/preferred first."
  @spec supported_versions() :: [String.t(), ...]
  def supported_versions, do: @supported_versions

  @doc """
  Returns the JSON-RPC version.
  """
  @spec jsonrpc_version() :: String.t()
  def jsonrpc_version, do: @jsonrpc_version

  @doc """
  Encodes a message struct to a JSON string.
  """
  @spec encode(Request.t() | Response.t() | Notification.t()) ::
          {:ok, String.t()} | {:error, term()}
  def encode(message) do
    {:ok, Jason.encode!(message)}
  rescue
    e -> {:error, e}
  end

  @doc """
  Encodes a message struct to a JSON string, raising on error.
  """
  @spec encode!(Request.t() | Response.t() | Notification.t()) :: String.t()
  def encode!(message) do
    Jason.encode!(message)
  end

  @doc """
  Decodes a JSON string into a classified message struct.
  """
  @spec decode(String.t()) ::
          {:ok, Request.t() | Response.t() | Notification.t()} | {:error, Error.t()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> decode_message(map)
      {:error, _} -> {:error, Error.parse_error()}
    end
  end

  @doc """
  Classifies a decoded JSON map into the appropriate message struct.
  """
  @spec decode_message(map()) ::
          {:ok, Request.t() | Response.t() | Notification.t()} | {:error, Error.t()}
  def decode_message(%{"jsonrpc" => "2.0"} = map) do
    cond do
      # Response: has "id" and ("result" or "error")
      Map.has_key?(map, "id") and (Map.has_key?(map, "result") or Map.has_key?(map, "error")) ->
        decode_response(map)

      # Request: has "id" and "method"
      Map.has_key?(map, "id") and Map.has_key?(map, "method") ->
        {:ok, decode_request(map)}

      # Notification: has "method" but no "id"
      Map.has_key?(map, "method") and not Map.has_key?(map, "id") ->
        {:ok, decode_notification(map)}

      true ->
        {:error, Error.invalid_request()}
    end
  end

  def decode_message(_map) do
    {:error, Error.invalid_request("Missing or invalid jsonrpc version")}
  end

  defp decode_request(map) do
    %Request{
      id: Map.fetch!(map, "id"),
      method: Map.fetch!(map, "method"),
      params: Map.get(map, "params")
    }
  end

  defp decode_response(%{"error" => error_map} = map) do
    case error_map do
      %{"code" => code, "message" => message} when is_integer(code) and is_binary(message) ->
        {:ok,
         %Response{
           id: Map.fetch!(map, "id"),
           result: Map.get(map, "result"),
           error: Error.from_map(error_map)
         }}

      _invalid_error ->
        {:error, Error.invalid_request("response error must contain integer code and message")}
    end
  end

  defp decode_response(map),
    do: {:ok, %Response{id: Map.fetch!(map, "id"), result: Map.get(map, "result")}}

  defp decode_notification(map) do
    %Notification{
      method: Map.fetch!(map, "method"),
      params: Map.get(map, "params")
    }
  end
end
