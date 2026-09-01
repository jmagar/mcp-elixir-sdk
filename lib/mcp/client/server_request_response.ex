defmodule MCP.Client.ServerRequestResponse do
  @moduledoc false

  alias MCP.Protocol.Error

  @spec encode(term(), {:ok, term()} | {:error, Error.t()} | term()) :: map()
  def encode(id, {:ok, result}),
    do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  def encode(id, {:error, %Error{} = error}) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => Error.to_map(error)}
  end

  def encode(id, _invalid),
    do: encode(id, {:error, Error.internal_error("invalid client handler result")})
end
