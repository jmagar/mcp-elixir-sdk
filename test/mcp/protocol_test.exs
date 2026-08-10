defmodule MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol
  alias MCP.Protocol.Error
  alias MCP.Protocol.Messages.{Notification, Request, Response}

  describe "protocol_version/0" do
    test "returns the target MCP version" do
      assert Protocol.protocol_version() == "2026-07-28"
    end
  end

  describe "encode/1" do
    test "encodes a request" do
      request = Request.new(1, "tools/list", %{"cursor" => "abc"})
      assert {:ok, json} = Protocol.encode(request)
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["method"] == "tools/list"
      assert decoded["params"] == %{"cursor" => "abc"}
    end

    test "encodes a request without params" do
      request = Request.new(1, "ping")
      assert {:ok, json} = Protocol.encode(request)
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["method"] == "ping"
      refute Map.has_key?(decoded, "params")
    end

    test "encodes a success response" do
      response = Response.success(1, %{"tools" => []})
      assert {:ok, json} = Protocol.encode(response)
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["result"] == %{"tools" => []}
      refute Map.has_key?(decoded, "error")
    end

    test "encodes an error response" do
      error = Error.method_not_found("unknown/method")
      response = Response.error(1, error)
      assert {:ok, json} = Protocol.encode(response)
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["error"]["code"] == -32_601
      assert decoded["error"]["message"] == "Method not found"
      refute Map.has_key?(decoded, "result")
    end

    test "encodes a notification" do
      notification = Notification.new("notifications/tools/list_changed")
      assert {:ok, json} = Protocol.encode(notification)
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "notifications/tools/list_changed"
      refute Map.has_key?(decoded, "id")
      refute Map.has_key?(decoded, "params")
    end

    test "encodes a notification with params" do
      notification = Notification.new("notifications/resources/updated", %{"uri" => "file:///a"})
      assert {:ok, json} = Protocol.encode(notification)
      decoded = Jason.decode!(json)

      assert decoded["params"] == %{"uri" => "file:///a"}
    end
  end

  describe "decode/1" do
    test "decodes a request" do
      json = ~s({"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"weather"}})
      assert {:ok, %Request{} = request} = Protocol.decode(json)

      assert request.id == 42
      assert request.method == "tools/call"
      assert request.params == %{"name" => "weather"}
    end

    test "decodes a request with string id" do
      json = ~s({"jsonrpc":"2.0","id":"abc-123","method":"ping"})
      assert {:ok, %Request{} = request} = Protocol.decode(json)
      assert request.id == "abc-123"
    end

    test "decodes a success response" do
      json = ~s({"jsonrpc":"2.0","id":1,"result":{"tools":[]}})
      assert {:ok, %Response{} = response} = Protocol.decode(json)

      assert response.id == 1
      assert response.result == %{"tools" => []}
      assert response.error == nil
    end

    test "decodes an error response" do
      json = ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}})
      assert {:ok, %Response{} = response} = Protocol.decode(json)

      assert response.id == 1
      assert response.result == nil
      assert response.error.code == -32_601
      assert response.error.message == "Method not found"
    end

    test "decodes a notification" do
      json = ~s({"jsonrpc":"2.0","method":"notifications/initialized"})
      assert {:ok, %Notification{} = notification} = Protocol.decode(json)

      assert notification.method == "notifications/initialized"
      assert notification.params == nil
    end

    test "returns parse error for invalid JSON" do
      assert {:error, %Error{code: -32_700}} = Protocol.decode("not json")
    end

    test "returns invalid request for missing jsonrpc version" do
      assert {:error, %Error{code: -32_600}} = Protocol.decode(~s({"method":"ping"}))
    end

    test "returns invalid request for wrong jsonrpc version" do
      assert {:error, %Error{code: -32_600}} =
               Protocol.decode(~s({"jsonrpc":"1.0","method":"ping"}))
    end

    test "returns invalid request for ambiguous message" do
      assert {:error, %Error{code: -32_600}} =
               Protocol.decode(~s({"jsonrpc":"2.0"}))
    end
  end

  describe "decode_message/1" do
    test "classifies response when both id and result present" do
      map = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
      assert {:ok, %Response{}} = Protocol.decode_message(map)
    end

    test "classifies response when both id and error present" do
      map = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "error" => %{"code" => -32_600, "message" => "Invalid"}
      }

      assert {:ok, %Response{}} = Protocol.decode_message(map)
    end

    test "rejects malformed response error objects without raising" do
      for malformed <- ["scalar", %{}, %{"code" => "bad", "message" => 7}] do
        map = %{"jsonrpc" => "2.0", "id" => 1, "error" => malformed}
        assert {:error, %Error{code: -32_600}} = Protocol.decode_message(map)
      end
    end

    test "classifies request when id and method present (no result/error)" do
      map = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}
      assert {:ok, %Request{}} = Protocol.decode_message(map)
    end

    test "classifies notification when method present without id" do
      map = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      assert {:ok, %Notification{}} = Protocol.decode_message(map)
    end
  end

  describe "encode!/1" do
    test "returns JSON string" do
      request = Request.new(1, "ping")
      json = Protocol.encode!(request)
      assert is_binary(json)
      assert Jason.decode!(json)["method"] == "ping"
    end
  end
end
