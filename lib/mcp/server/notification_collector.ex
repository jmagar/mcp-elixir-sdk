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
  @spec start_link() :: {:ok, pid()}
  def start_link, do: Agent.start_link(fn -> [] end)

  @doc """
  Appends a notification to the collector, preserving emission order.

  The notification is encoded to its wire map in the caller process; only a
  trivial list prepend runs inside the collector.
  """
  @spec push(pid(), String.t(), map()) :: :ok
  def push(collector, method, params) do
    encoded = Jason.decode!(Jason.encode!(Notification.new(method, params)))
    Agent.update(collector, fn acc -> [encoded | acc] end)
  end

  @doc """
  Returns all collected notifications in emission order.
  """
  @spec drain(pid()) :: [map()]
  def drain(collector), do: Agent.get(collector, &Enum.reverse/1)

  @doc """
  Stops the collector. Hygiene: the safety property holds without it (see the
  module doc), but this reclaims the process promptly on both the normal and
  the raising exit path.
  """
  @spec stop(pid()) :: :ok
  def stop(collector), do: Agent.stop(collector)
end
