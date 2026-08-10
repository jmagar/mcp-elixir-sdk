defmodule MCP.Protocol.Meta do
  @moduledoc """
  Per-request `_meta` handling for the MCP 2026-07-28 stateless core.

  The stateless core removes the `initialize` handshake (SEP-2575): protocol
  version, client info and client capabilities are no longer negotiated once
  per session — they ride in **every request's** `_meta`, under fully-qualified
  `io.modelcontextprotocol/*` keys.

  Keys parsed here (request side):

    * `io.modelcontextprotocol/protocolVersion` — the client's protocol version
      (required; a missing or malformed value is invalid params, while a
      well-formed unsupported version fails with `UnsupportedProtocolVersion`,
      -32022).
    * `io.modelcontextprotocol/clientInfo` — client identity (SHOULD).
    * `io.modelcontextprotocol/clientCapabilities` — client capabilities.
    * `io.modelcontextprotocol/logLevel` — the per-request log level, replacing
      the removed `logging/setLevel` control method (the Logging feature itself
      is retained-deprecated).

  ## W3C Trace Context passthrough (SEP-414)

  Distributed-tracing propagation rides `_meta` under the standard W3C key
  names `traceparent` / `tracestate` / `baggage` (SEP-414 is a convention, not
  a schema-defined shape — these keys are absent from `schema/draft/schema.ts`).
  This module extracts them for observability; the raw `_meta` is preserved on
  `:raw` so a stateless transport can pass the context through unmodified.

  This module reads `_meta` from a decoded request/notification's `params`; it
  never derives any caller **identity** — that comes from the authenticated
  transport pipeline (see the identity-threading design spec), never from the
  message body.
  """

  @protocol_version_key "io.modelcontextprotocol/protocolVersion"
  @client_info_key "io.modelcontextprotocol/clientInfo"
  @client_capabilities_key "io.modelcontextprotocol/clientCapabilities"
  @log_level_key "io.modelcontextprotocol/logLevel"

  # W3C Trace Context (SEP-414) — standard header names carried in _meta.
  @traceparent_key "traceparent"
  @tracestate_key "tracestate"
  @baggage_key "baggage"
  @trace_keys [@traceparent_key, @tracestate_key, @baggage_key]

  defstruct [
    :protocol_version,
    :client_info,
    :client_capabilities,
    :log_level,
    :trace_context,
    raw: %{}
  ]

  @type t :: %__MODULE__{
          protocol_version: String.t() | nil,
          client_info: map() | nil,
          client_capabilities: map() | nil,
          log_level: String.t() | nil,
          trace_context: map() | nil,
          raw: map()
        }

  def protocol_version_key, do: @protocol_version_key
  def client_info_key, do: @client_info_key
  def client_capabilities_key, do: @client_capabilities_key
  def log_level_key, do: @log_level_key
  def trace_keys, do: @trace_keys

  @doc """
  Validates the metadata fields required on every 2026-07-28 request.

  Structural failures are invalid request parameters (`-32602`), not protocol
  negotiation failures. A well-formed but unsupported version is handled
  separately by `validate_protocol_version/2`.
  """
  @spec validate_required(t()) :: :ok | {:error, atom()}
  def validate_required(%__MODULE__{raw: raw, protocol_version: version} = meta) do
    cond do
      map_size(raw) == 0 -> {:error, :missing_meta}
      not is_binary(version) -> {:error, :missing_protocol_version}
      not is_map(meta.client_capabilities) -> {:error, :missing_client_capabilities}
      true -> :ok
    end
  end

  @doc """
  Extracts the per-request `_meta` keys from a request/notification's `params`.

  Accepts the full `params` map (reads its `"_meta"`) or `nil`.
  """
  @spec from_params(map() | nil) :: t()
  def from_params(params) when is_map(params) do
    case Map.get(params, "_meta") do
      meta when is_map(meta) -> from_meta(meta)
      _missing_or_invalid -> %__MODULE__{raw: %{}}
    end
  end

  def from_params(_), do: %__MODULE__{raw: %{}}

  @doc """
  Builds a `#{inspect(__MODULE__)}` from an already-extracted `_meta` map.
  """
  @spec from_meta(map()) :: t()
  def from_meta(meta) when is_map(meta) do
    %__MODULE__{
      protocol_version: Map.get(meta, @protocol_version_key),
      client_info: Map.get(meta, @client_info_key),
      client_capabilities: Map.get(meta, @client_capabilities_key),
      log_level: Map.get(meta, @log_level_key),
      trace_context: extract_trace_context(meta),
      raw: meta
    }
  end

  # Returns the W3C trace-context subset of `_meta`, or `nil` when none present.
  defp extract_trace_context(meta) do
    ctx = Map.take(meta, @trace_keys)
    if map_size(ctx) > 0, do: ctx, else: nil
  end

  @doc """
  Validates the request's protocol version against the version this server
  supports.

  Returns `:ok`, `{:error, :missing}` when no version is present, or
  `{:error, {:unsupported, got}}` when it does not match. The dispatch boundary
  rejects missing required metadata as invalid params (`-32602`) and maps only
  a well-formed unsupported version to `UnsupportedProtocolVersion` (`-32022`).
  """
  @spec validate_protocol_version(t(), String.t()) ::
          :ok | {:error, :missing} | {:error, {:unsupported, String.t()}}
  def validate_protocol_version(%__MODULE__{protocol_version: nil}, _supported),
    do: {:error, :missing}

  def validate_protocol_version(%__MODULE__{protocol_version: supported}, supported), do: :ok

  def validate_protocol_version(%__MODULE__{protocol_version: got}, _supported),
    do: {:error, {:unsupported, got}}
end
