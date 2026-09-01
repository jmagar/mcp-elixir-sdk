defmodule MCP.Server.NotificationCollector do
  @moduledoc """
  Per-request notification collector for the stateless HTTP driver.

  Replaces the process-dictionary collector that produced the Sprint 3
  cross-request identity leak (evidence-log I10). The collector is a small
  per-request process; its pid is held **only** by that request's `reply_sink`
  closure on that request's `MCP.Server.ToolContext`. There is no
  process-keyed global slot, so a *subsequent* request holds no reference by
  which it could address a prior request's collector — residue is
  **unaddressable, not merely cleared** (MES-14 AC2, reachability-bounded).

  Lifecycle, entirely within a single `dispatch` call frame:

      {:ok, c} = NotificationCollector.start_link()
      # ctx.reply_sink = fn method, params -> NotificationCollector.push(c, method, params) end
      # ... dispatch runs synchronously; the handler emits via the sink ...
      notifications = NotificationCollector.drain(c)   # in emission order
      NotificationCollector.stop(c)                    # in an `after` — hygiene, not correctness

  `start_link/0` **links** the collector to the caller (the request process):
  a request-process crash takes the collector with it, so no orphan can
  outlive the request even if `stop/1` does not run. The safety property (no
  cross-request residue) does not depend on `stop/1` firing at all — it is a
  consequence of the collector being unreachable to any other request.

  The wire encoding (`Notification.new/2` round-tripped through JSON) is
  performed in the **caller** process before handing a plain map to the
  collector, so the collector's own state update cannot raise and take the
  linked request process down with it.
  """

  alias MCP.Protocol.Messages.Notification

  @doc """
  Starts a per-request collector, linked to the calling (request) process.
  """
  @default_max_notifications 256
  @default_max_bytes 1_000_000

  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) do
    max_notifications = Keyword.get(opts, :max_notifications, @default_max_notifications)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    unless is_integer(max_notifications) and max_notifications > 0,
      do: raise(ArgumentError, ":max_notifications must be a positive integer")

    unless is_integer(max_bytes) and max_bytes > 0,
      do: raise(ArgumentError, ":max_bytes must be a positive integer")

    Agent.start_link(fn ->
      %{
        notifications: [],
        count: 0,
        bytes: 0,
        max_notifications: max_notifications,
        max_bytes: max_bytes,
        overflowed?: false
      }
    end)
  end

  @doc false
  @spec configure(pid(), keyword()) :: :ok
  def configure(collector, opts) do
    max_notifications = Keyword.fetch!(opts, :max_notifications)
    max_bytes = Keyword.fetch!(opts, :max_bytes)

    Agent.update(collector, fn state ->
      %{state | max_notifications: max_notifications, max_bytes: max_bytes}
    end)
  end

  @doc """
  Appends a notification to the collector, preserving emission order.

  The notification is encoded to its wire map in the caller process; only a
  trivial list prepend runs inside the collector.
  """
  @spec push(pid(), String.t(), map()) :: :ok | {:error, :notification_limit_reached}
  def push(collector, method, params) do
    notification = Notification.new(method, params)
    encoded_json = Jason.encode_to_iodata!(notification)
    encoded_bytes = IO.iodata_length(encoded_json)
    encoded = notification_map(notification)

    Agent.get_and_update(collector, fn state ->
      if state.overflowed? or state.count + 1 > state.max_notifications or
           state.bytes + encoded_bytes > state.max_bytes do
        {{:error, :notification_limit_reached}, %{state | overflowed?: true}}
      else
        {:ok,
         %{
           state
           | notifications: [encoded | state.notifications],
             count: state.count + 1,
             bytes: state.bytes + encoded_bytes
         }}
      end
    end)
  end

  defp notification_map(%Notification{jsonrpc: jsonrpc, method: method, params: nil}),
    do: %{"jsonrpc" => jsonrpc, "method" => method}

  defp notification_map(%Notification{jsonrpc: jsonrpc, method: method, params: params}),
    do: %{"jsonrpc" => jsonrpc, "method" => method, "params" => params}

  @doc """
  Returns all collected notifications in emission order.
  """
  @spec drain(pid()) :: [map()]
  def drain(collector),
    do: Agent.get(collector, fn state -> Enum.reverse(state.notifications) end)

  @doc "Returns whether the collector rejected one or more notifications."
  @spec overflowed?(pid()) :: boolean()
  def overflowed?(collector), do: Agent.get(collector, & &1.overflowed?)

  @doc """
  Stops the collector. Hygiene: the safety property holds without it (see the
  module doc), but this reclaims the process promptly on both the normal and
  the raising exit path.
  """
  @spec stop(pid()) :: :ok
  def stop(collector), do: Agent.stop(collector)
end
