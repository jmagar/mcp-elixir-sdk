defmodule MCP.Server.ToolContext do
  @moduledoc """
  Per-request context passed to identity-capable handler callbacks.

  In the 2026-07-28 stateless core this struct is **the per-request handler
  context**: it is constructed once per request by the transport driver and
  handed to every identity-capable callback via `MCP.Server.Dispatch`. Under
  2025-11-25, the same struct is created for each request inside the negotiated
  connection or HTTP session and passed through `MCP.Server.LegacyDispatch`.

  ## The `:identity` field (security-critical)

  `:identity` holds the caller principal established by the **authenticated
  transport pipeline** — for HTTP, resolved per request from `conn`; for
  stdio/in-process, resolved once at launch (PO Comment B). It is populated by
  the transport driver **before** the handler runs and is **never** derived
  from the JSON-RPC `params`/`arguments`. Handlers MUST read the caller
  identity from `ctx.identity`, never from a model-supplied argument.

  ## The `:input` field (MRTR continuation — NOT identity)

  For Multi Round-Trip Requests (SEP-2322), a resumed request carries the
  server's continuation token and the client's fulfilled inputs. `:input` is
  `nil` on a first attempt, or
  `%{request_state: binary() | nil, responses: term()}` on a retry. Ephemeral
  input flows can omit `requestState`. `MCP.Server.Dispatch` populates it from the request `params`
  (`requestState` / `inputResponses`) before invoking the handler. It is
  handler-continuation data, orthogonal to identity.

  ## The `:reply_sink` field (per-request notification emitter)

  The 2026 stateless core removes the per-session server GenServer, so a handler can
  no longer `GenServer.call` a long-lived server to emit progress/logging
  notifications (dispatch runs synchronously *inside* the transport driver
  process — such a call would self-deadlock). Instead, `:reply_sink` is an
  optional `(method, params -> :ok)` function bound by the driver to that
  request's outbound channel. When `nil`, notifications are dropped.

  Server→client **requests** are not made through this context. In 2026 they
  convert to MRTR (a handler returns
  `{:input_required, input_requests, request_state}`, which
  `Dispatch` shapes into an `InputRequiredResult`; the client fulfils the
  inputs and retries carrying `requestState`). In 2025, `MCP.Server.Connection`
  converts the same handler result into correlated sampling, roots, or
  elicitation requests over the negotiated session and resumes the handler.
  """

  defstruct [:request_id, :meta, :identity, :input, :reply_sink]

  @type input :: %{request_state: binary() | nil, responses: term()} | nil

  @type t :: %__MODULE__{
          request_id: term(),
          meta: map() | nil,
          identity: term() | nil,
          input: input(),
          reply_sink: (String.t(), map() -> :ok) | nil
        }

  @doc """
  Sends a JSON-RPC notification to the client during request handling.

  Routed through the per-request `:reply_sink`. A no-op when no sink is bound
  (e.g. an HTTP JSON-mode response with no open stream).
  """
  @spec send_notification(t(), String.t(), map()) :: :ok
  def send_notification(%__MODULE__{reply_sink: sink}, method, params)
      when is_function(sink, 2) do
    sink.(method, params)
    :ok
  end

  def send_notification(%__MODULE__{}, _method, _params), do: :ok

  @doc """
  Sends a log message notification to the client (convenience over
  `send_notification/3`).
  """
  @spec log(t(), String.t(), term(), String.t() | nil) :: :ok
  def log(%__MODULE__{} = ctx, level, data, logger \\ nil) do
    params = %{"level" => level, "data" => data}
    params = if logger, do: Map.put(params, "logger", logger), else: params
    send_notification(ctx, "notifications/message", params)
  end

  @doc """
  Sends a progress notification to the client. Uses the `progressToken` from
  `_meta` when available.
  """
  @spec send_progress(t(), number(), number() | nil) :: :ok
  def send_progress(%__MODULE__{} = ctx, progress, total \\ nil) do
    token = get_progress_token(ctx)

    params = %{"progressToken" => token, "progress" => progress}
    params = if total, do: Map.put(params, "total", total), else: params
    send_notification(ctx, "notifications/progress", params)
  end

  defp get_progress_token(%__MODULE__{meta: meta}) when is_map(meta) do
    Map.get(meta, "progressToken", 0)
  end

  defp get_progress_token(_ctx), do: 0
end
