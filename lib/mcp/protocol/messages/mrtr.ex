defmodule MCP.Protocol.Messages.MRTR do
  @moduledoc """
  Multi Round-Trip Requests (MRTR) for the MCP 2026-07-28 stateless core
  (SEP-2322).

  The stateless core removes the held-open SSE server→client request path
  (sampling/elicitation). Instead, when a server handler needs client-provided
  input mid-request, it returns an **`InputRequiredResult`** — a normal
  JSON-RPC *result* with `resultType: "input_required"` — carrying the input
  requests and an opaque `requestState` continuation token. The client fulfils
  the inputs and **retries the original request**, passing back `inputResponses`
  and `requestState` (SEP-2260 is satisfied by construction: the input-required
  reply *is* the response to an active client request).

  ## Wire shape — verified against the pinned published-final schema

  Commit `5f5440bb26a62e2cf3440b92da5a667efa03b267` (tag `2026-07-28`,
  2026-07-28), `schema/2026-07-28/schema.ts`:

    * `Result` (schema.ts:223) requires `resultType: ResultType`
      (`"complete" | "input_required" | string`; `ResultType` at schema.ts:216,
      the field at schema.ts:234).
    * `InputRequiredResult extends Result` (schema.ts:584) adds
      **`inputRequests?: InputRequests`** (schema.ts:588) and
      **`requestState?: string`** (schema.ts:594); at least one must be present.
    * On retry the client sends `InputResponseRequestParams` (schema.ts:600)
      carrying **`inputResponses?`** (schema.ts:605) and **`requestState?`**
      (schema.ts:608) on the request **params** (not `_meta`).
  """

  @result_type "input_required"

  @doc "The `resultType` marker for an input-required result."
  def result_type, do: @result_type

  @doc """
  Builds the wire map for an `InputRequiredResult`.

  `input_requests` is a string-keyed map of input-request objects (opaque here);
  `request_state` is the opaque continuation token the client echoes on retry.
  At least one of the two is emitted.
  """
  @spec input_required(map() | nil, binary() | nil) :: map()
  def input_required(input_requests, request_state)
      when (is_map(input_requests) or is_nil(input_requests)) and
             (is_binary(request_state) or is_nil(request_state)) and
             not (is_nil(input_requests) and is_nil(request_state)) do
    base = %{"resultType" => @result_type}
    base = if input_requests, do: Map.put(base, "inputRequests", input_requests), else: base
    if request_state, do: Map.put(base, "requestState", request_state), else: base
  end

  def input_required(_input_requests, _request_state) do
    raise ArgumentError,
          "input-required results need a map of input requests and/or a binary request state"
  end

  @doc """
  Extracts the MRTR continuation from a request's `params`, or `nil` when the
  request is a first attempt.

  Returns `%{request_state: binary() | nil, responses: map() | nil}` when either
  `requestState` or `inputResponses` is present. Ephemeral MRTR flows may omit
  state and resume using only input responses. Malformed continuation fields
  return `{:error, reason}` so transports can produce Invalid Params without
  invoking consumer code.
  """
  @spec continuation_from_params(map() | nil) ::
          %{request_state: binary() | nil, responses: map() | nil} | nil | {:error, atom()}
  def continuation_from_params(params) when is_map(params) do
    state? = Map.has_key?(params, "requestState")
    responses? = Map.has_key?(params, "inputResponses")
    request_state = Map.get(params, "requestState")
    responses = Map.get(params, "inputResponses")

    cond do
      state? and not is_binary(request_state) -> {:error, :request_state_must_be_a_string}
      responses? and not is_map(responses) -> {:error, :input_responses_must_be_an_object}
      state? or responses? -> %{request_state: request_state, responses: responses}
      true -> nil
    end
  end

  def continuation_from_params(_), do: nil
end
