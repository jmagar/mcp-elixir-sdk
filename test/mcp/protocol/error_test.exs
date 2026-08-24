defmodule MCP.Protocol.ErrorTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Error

  describe "error codes" do
    test "standard JSON-RPC error codes" do
      assert Error.parse_error_code() == -32_700
      assert Error.invalid_request_code() == -32_600
      assert Error.method_not_found_code() == -32_601
      assert Error.invalid_params_code() == -32_602
      assert Error.internal_error_code() == -32_603
    end

    test "MCP spec-reserved error codes (2026-07-28)" do
      assert Error.header_mismatch_code() == -32_020
      assert Error.missing_required_client_capability_code() == -32_021
      assert Error.unsupported_protocol_version_code() == -32_022
    end

    test "resource-not-found maps to standard Invalid Params (SEP-2164)" do
      assert Error.resource_not_found_code() == -32_602
    end
  end

  describe "constructor helpers" do
    test "parse_error/0" do
      error = Error.parse_error()
      assert error.code == -32_700
      assert error.message == "Parse error"
      assert error.data == nil
    end

    test "parse_error/1 with data" do
      error = Error.parse_error("unexpected token")
      assert error.code == -32_700
      assert error.data == "unexpected token"
    end

    test "invalid_request/0" do
      error = Error.invalid_request()
      assert error.code == -32_600
      assert error.message == "Invalid request"
    end

    test "method_not_found/1" do
      error = Error.method_not_found("unknown/method")
      assert error.code == -32_601
      assert error.data == "unknown/method"
    end

    test "invalid_params/1" do
      error = Error.invalid_params("missing required field")
      assert error.code == -32_602
      assert error.data == "missing required field"
    end

    test "internal_error/0" do
      error = Error.internal_error()
      assert error.code == -32_603
      assert error.message == "Internal error"
    end

    test "resource_not_found/1 uses -32602 (SEP-2164)" do
      error = Error.resource_not_found("file:///missing")
      assert error.code == -32_602
      assert error.data == "file:///missing"
    end

    test "unsupported_protocol_version/1" do
      error = Error.unsupported_protocol_version("2025-11-25")
      assert error.code == -32_022
      assert error.message == "Unsupported protocol version"
      assert error.data == "2025-11-25"
    end

    test "header_mismatch/1 and missing_required_client_capability/1" do
      assert Error.header_mismatch("Mcp-Method").code == -32_020
      assert Error.missing_required_client_capability("sampling").code == -32_021
    end
  end

  describe "JSON encoding" do
    test "encodes to JSON with all fields" do
      error = Error.parse_error("bad json")
      json = Jason.encode!(error)
      decoded = Jason.decode!(json)

      assert decoded["code"] == -32_700
      assert decoded["message"] == "Parse error"
      assert decoded["data"] == "bad json"
    end

    test "encodes nil data as null" do
      error = Error.parse_error()
      json = Jason.encode!(error)
      decoded = Jason.decode!(json)

      assert decoded["code"] == -32_700
      assert decoded["data"] == nil
    end
  end

  describe "from_map/1" do
    test "parses error from wire format" do
      map = %{"code" => -32_601, "message" => "Method not found", "data" => "foo/bar"}
      error = Error.from_map(map)

      assert error.code == -32_601
      assert error.message == "Method not found"
      assert error.data == "foo/bar"
    end

    test "parses error without data" do
      map = %{"code" => -32_603, "message" => "Internal error"}
      error = Error.from_map(map)

      assert error.code == -32_603
      assert error.data == nil
    end

    test "round-trips unknown fields at the schema-open Error boundary" do
      map = %{
        "code" => -32_603,
        "message" => "Internal error",
        "data" => nil,
        "vendor" => %{"retryable" => false}
      }

      error = Error.from_map(map)
      assert error.extra == %{"vendor" => %{"retryable" => false}}
      assert Jason.decode!(Jason.encode!(error)) == map

      assert_raise ArgumentError, ~r/collides with code/, fn ->
        Jason.encode!(%{error | extra: %{"code" => 1}})
      end
    end
  end
end
