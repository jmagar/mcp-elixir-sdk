defmodule MCP.Protocol.Error do
  @moduledoc """
  MCP protocol error codes and error struct.

  Covers standard JSON-RPC 2.0 error codes and the MCP-specific error codes of
  the 2026-07-28 stateless core.

  ## Error-code allocation policy (2026-07-28)

    * `-32000..-32019` — implementation-defined (existing SDK usage is
      grandfathered).
    * `-32020..-32099` — **reserved for the MCP specification.**

  The spec-reserved codes this SDK emits:

    * `HeaderMismatch` — `-32020`
    * `MissingRequiredClientCapability` — `-32021`
    * `UnsupportedProtocolVersion` — `-32022`

  Missing-resource errors use the standard JSON-RPC `-32602` (Invalid Params)
  as of 2026-07-28 (SEP-2164); the previous MCP-specific `-32002` is retired.
  The `-32042` URL-elicitation error is removed together with the retired async
  completion-correlation machinery (the `elicitationId` field and
  `notifications/elicitation/complete`). **URL-mode elicitation itself is
  RETAINED** (PO Ruling 5 — the draft schema keeps `ElicitRequestURLParams`,
  `mode: "url"`, `url`, and the client `elicitation.url` capability); only the
  `-32042` helper is dropped.
  """

  @derive Jason.Encoder
  defstruct [:code, :message, :data]

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: term()
        }

  # Standard JSON-RPC 2.0 error codes
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603

  # MCP spec-reserved error codes (-32020..-32099)
  @header_mismatch -32_020
  @missing_required_client_capability -32_021
  @unsupported_protocol_version -32_022

  # Missing-resource now maps to standard Invalid Params (SEP-2164).
  @resource_not_found -32_602

  def parse_error_code, do: @parse_error
  def invalid_request_code, do: @invalid_request
  def method_not_found_code, do: @method_not_found
  def invalid_params_code, do: @invalid_params
  def internal_error_code, do: @internal_error
  def header_mismatch_code, do: @header_mismatch
  def missing_required_client_capability_code, do: @missing_required_client_capability
  def unsupported_protocol_version_code, do: @unsupported_protocol_version
  def resource_not_found_code, do: @resource_not_found

  @spec parse_error(term()) :: t()
  def parse_error(data \\ nil) do
    %__MODULE__{code: @parse_error, message: "Parse error", data: data}
  end

  @spec invalid_request(term()) :: t()
  def invalid_request(data \\ nil) do
    %__MODULE__{code: @invalid_request, message: "Invalid request", data: data}
  end

  @spec method_not_found(String.t() | nil) :: t()
  def method_not_found(method \\ nil) do
    %__MODULE__{code: @method_not_found, message: "Method not found", data: method}
  end

  @spec invalid_params(term()) :: t()
  def invalid_params(data \\ nil) do
    %__MODULE__{code: @invalid_params, message: "Invalid params", data: data}
  end

  @spec internal_error(term()) :: t()
  def internal_error(data \\ nil) do
    %__MODULE__{code: @internal_error, message: "Internal error", data: data}
  end

  @doc """
  Header mismatch (`-32020`). A routing header (`Mcp-Method`/`Mcp-Name`) does
  not match the request body.
  """
  @spec header_mismatch(term()) :: t()
  def header_mismatch(data \\ nil) do
    %__MODULE__{code: @header_mismatch, message: "Header mismatch", data: data}
  end

  @doc """
  Missing required client capability (`-32021`).
  """
  @spec missing_required_client_capability(term()) :: t()
  def missing_required_client_capability(data \\ nil) do
    %__MODULE__{
      code: @missing_required_client_capability,
      message: "Missing required client capability",
      data: data
    }
  end

  @doc """
  Unsupported protocol version (`-32022`). Returned when a request selects a
  version outside `MCP.Protocol.supported_versions/0`, or when a 2026 request
  omits its required `io.modelcontextprotocol/protocolVersion` metadata.
  """
  @spec unsupported_protocol_version(term()) :: t()
  def unsupported_protocol_version(data \\ nil) do
    %__MODULE__{
      code: @unsupported_protocol_version,
      message: "Unsupported protocol version",
      data: data
    }
  end

  @doc """
  Resource not found. As of 2026-07-28 this is the standard `-32602` Invalid
  Params (SEP-2164), not the retired MCP-specific `-32002`.
  """
  @spec resource_not_found(String.t() | nil) :: t()
  def resource_not_found(uri \\ nil) do
    %__MODULE__{code: @resource_not_found, message: "Resource not found", data: uri}
  end

  @doc """
  Converts a wire-format map to an Error struct.
  """
  @spec from_map(map()) :: t()
  def from_map(%{"code" => code, "message" => message} = map) do
    %__MODULE__{
      code: code,
      message: message,
      data: Map.get(map, "data")
    }
  end
end
