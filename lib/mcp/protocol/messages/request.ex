defmodule MCP.Protocol.Messages.Request do
  @moduledoc """
  A JSON-RPC 2.0 request message.

  Requests have an `id` field and expect a response.
  """

  defstruct jsonrpc: "2.0", id: nil, method: nil, params: nil

  @type t :: %__MODULE__{
          jsonrpc: String.t(),
          id: integer() | String.t(),
          method: String.t(),
          params: map() | nil
        }

  @spec new(integer() | String.t(), String.t(), map() | nil) :: t()
  def new(id, method, params \\ nil) do
    %__MODULE__{id: id, method: method, params: params}
  end

  defimpl Jason.Encoder, for: __MODULE__ do
    def encode(struct, opts) do
      map = %{jsonrpc: struct.jsonrpc, id: struct.id, method: struct.method}

      map =
        case struct.params do
          nil -> map
          params -> Map.put(map, :params, params)
        end

      Jason.Encode.map(map, opts)
    end
  end
end
