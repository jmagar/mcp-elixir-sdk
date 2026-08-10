defmodule MCP.Protocol.Messages.Notification do
  @moduledoc """
  A JSON-RPC 2.0 notification message.

  Notifications have no `id` and do not expect a response.
  """

  defstruct jsonrpc: "2.0", method: nil, params: nil

  @type t :: %__MODULE__{
          jsonrpc: String.t(),
          method: String.t(),
          params: map() | nil
        }

  @spec new(String.t(), map() | nil) :: t()
  def new(method, params \\ nil) do
    %__MODULE__{method: method, params: params}
  end

  defimpl Jason.Encoder, for: __MODULE__ do
    def encode(struct, opts) do
      map = %{jsonrpc: struct.jsonrpc, method: struct.method}

      map =
        case struct.params do
          nil -> map
          params -> Map.put(map, :params, params)
        end

      Jason.Encode.map(map, opts)
    end
  end
end
