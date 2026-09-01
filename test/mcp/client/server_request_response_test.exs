defmodule MCP.Client.ServerRequestResponseTest do
  use ExUnit.Case, async: true

  alias MCP.Client.ServerRequestResponse
  alias MCP.Protocol.Error

  test "encodes successful and failed server request responses" do
    assert ServerRequestResponse.encode(1, {:ok, %{"ok" => true}}) == %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{"ok" => true}
           }

    assert ServerRequestResponse.encode(2, {:error, Error.invalid_params(%{field: "x"})}) ==
             %{
               "jsonrpc" => "2.0",
               "id" => 2,
               "error" => %{
                 "code" => -32_602,
                 "message" => "Invalid params",
                 "data" => %{field: "x"}
               }
             }
  end

  test "normalizes invalid handler results" do
    assert %{
             "error" => %{
               "code" => -32_603,
               "message" => "Internal error",
               "data" => "invalid client handler result"
             }
           } =
             ServerRequestResponse.encode("request", :invalid)
  end
end
