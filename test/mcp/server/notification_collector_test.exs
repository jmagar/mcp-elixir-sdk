defmodule MCP.Server.NotificationCollectorTest do
  @moduledoc """
  MES-14 — unit tests for the per-request notification collector that replaces
  the process-dictionary collector (evidence-log I10). Covers the `reply_sink`
  guarantee G3 (ordered, synchronous accumulation) at the collector's own level;
  the SSE-shaping-level cross-request isolation (AC3) lives in
  `streamable_http_stateless_test.exs`.
  """
  use ExUnit.Case, async: true

  alias MCP.Server.NotificationCollector, as: Collector

  test "drain returns pushed notifications as wire maps, in emission order (G3)" do
    {:ok, c} = Collector.start_link()

    :ok = Collector.push(c, "notifications/message", %{"level" => "info", "data" => "first"})
    :ok = Collector.push(c, "notifications/progress", %{"progress" => 1})
    :ok = Collector.push(c, "notifications/message", %{"level" => "info", "data" => "third"})

    drained = Collector.drain(c)
    Collector.stop(c)

    assert Enum.map(drained, & &1["method"]) ==
             ["notifications/message", "notifications/progress", "notifications/message"]

    # Wire form: JSON-RPC 2.0 notification maps (no id).
    assert Enum.all?(drained, &(&1["jsonrpc"] == "2.0"))
    refute Enum.any?(drained, &Map.has_key?(&1, "id"))
    assert hd(drained)["params"]["data"] == "first"
  end

  test "a fresh collector drains empty" do
    {:ok, c} = Collector.start_link()
    assert Collector.drain(c) == []
    Collector.stop(c)
  end

  test "two collectors are independent — one holds no reference to the other (AC2)" do
    {:ok, a} = Collector.start_link()
    {:ok, b} = Collector.start_link()

    Collector.push(a, "notifications/message", %{"data" => "A-only"})

    # b was started separately; it has no way to name a's state.
    assert Collector.drain(b) == []
    assert [%{"params" => %{"data" => "A-only"}}] = Collector.drain(a)

    Collector.stop(a)
    Collector.stop(b)
  end

  test "the collector is linked to the caller; stop terminates it" do
    {:ok, c} = Collector.start_link()
    assert Process.alive?(c)
    :ok = Collector.stop(c)
    refute Process.alive?(c)
  end

  test "pushing to a stopped collector fails loudly, not silently (A6 item 1)" do
    {:ok, c} = Collector.start_link()
    Collector.stop(c)

    # A handler that stashed a *prior* request's sink and invoked it during a
    # later request hits that request's now-stopped collector. Under the old
    # process-dictionary collector this was a silent cross-request write; here
    # it is a loud exit against a dead process — no data reaches any other
    # request's response.
    assert catch_exit(Collector.push(c, "notifications/message", %{"data" => "late"}))
  end
end
