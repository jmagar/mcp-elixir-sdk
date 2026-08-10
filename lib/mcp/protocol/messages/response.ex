defmodule MCP.Protocol.Messages.Response do
  @moduledoc """
  A JSON-RPC 2.0 response message.

  Contains either a `result` or an `error`, never both.
  """

  alias MCP.Protocol.Error

  defstruct jsonrpc: "2.0", id: nil, result: nil, error: nil

  @type t :: %__MODULE__{
          jsonrpc: String.t(),
          id: integer() | String.t(),
          result: map() | nil,
          error: Error.t() | nil
        }

  @spec success(integer() | String.t(), map()) :: t()
  def success(id, result) do
    %__MODULE__{id: id, result: result}
  end

  @spec error(integer() | String.t(), Error.t()) :: t()
  def error(id, %Error{} = error) do
    %__MODULE__{id: id, error: error}
  end

  defimpl Jason.Encoder, for: __MODULE__ do
    def encode(struct, opts) do
      map = %{jsonrpc: struct.jsonrpc, id: struct.id}

      map =
        if struct.error != nil do
          Map.put(map, :error, struct.error)
        else
          Map.put(map, :result, struct.result || %{})
        end

      Jason.Encode.map(map, opts)
    end
  end
end
