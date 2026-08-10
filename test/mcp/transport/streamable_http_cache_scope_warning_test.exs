defmodule MCP.Transport.StreamableHTTPCacheScopeWarningTest do
  @moduledoc """
  MES-14 AC7 — the config-time cache-scope footgun warning: identity-dependent
  responses (a per-caller `handler_opts`) cached under a *public* scope with
  `ttlMs > 0`. Asserts (a) it fires on the risky config, (b) it is silent on the
  safe ones, and (c) it fires exactly once across N requests — because it is
  emitted from `Plug.init/1`, which runs once per configuration, never per
  request.

  Ratification condition C3 (surfacing): the last test starts the plug via the
  SDK's documented deployment shape — `Bandit.start_link(plug: {Mod, opts})` —
  and shows the warning reaches the **runtime** log there (Bandit calls
  `init/1` at server startup, not at compile time).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias MCP.Test.StatelessHandler
  alias MCP.Transport.StreamableHTTP.Plug, as: MCPPlug

  @version "2026-07-28"
  @meta %{
    "io.modelcontextprotocol/protocolVersion" => @version,
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }
  @needle "may be cached publicly"

  defp factory, do: fn conn -> [identity: conn.assigns[:role]] end

  defp init(extra), do: MCPPlug.init([server_mod: StatelessHandler] ++ extra)

  defp count(haystack, needle),
    do: haystack |> String.split(needle) |> length() |> Kernel.-(1)

  # --- AC7(a): fires on the risky configuration ---

  test "AC7(a): warns when a per-request identity factory meets public + ttlMs > 0" do
    log =
      capture_log(fn ->
        init(handler_opts: factory(), server_opts: [cache_defaults: {60_000, "public"}])
      end)

    assert log =~ @needle
    assert log =~ "private"
  end

  test "AC7(a): also warns for a STATIC handler_opts carrying an :identity" do
    log =
      capture_log(fn ->
        init(handler_opts: [identity: "svc"], server_opts: [cache_defaults: {60_000, "public"}])
      end)

    assert log =~ @needle
  end

  # --- AC7(b): silent on every safe configuration ---

  test "AC7(b)(i): silent when no identity is resolved (no handler_opts)" do
    log = capture_log(fn -> init(server_opts: [cache_defaults: {60_000, "public"}]) end)
    refute log =~ @needle
  end

  test "AC7(b)(i'): silent for a static handler_opts WITHOUT :identity" do
    log =
      capture_log(fn ->
        init(handler_opts: [foo: 1], server_opts: [cache_defaults: {60_000, "public"}])
      end)

    refute log =~ @needle
  end

  test "AC7(b)(ii): silent when the scope is private" do
    log =
      capture_log(fn ->
        init(handler_opts: factory(), server_opts: [cache_defaults: {60_000, "private"}])
      end)

    refute log =~ @needle
  end

  test "AC7(b)(iii): silent when ttlMs is 0 (the default no-store policy)" do
    log_default = capture_log(fn -> init(handler_opts: factory()) end)

    log_explicit_zero =
      capture_log(fn ->
        init(handler_opts: factory(), server_opts: [cache_defaults: {0, "public"}])
      end)

    refute log_default =~ @needle
    refute log_explicit_zero =~ @needle
  end

  # --- AC7(c): exactly once across N requests (config-time, not per request) ---

  test "AC7(c): N requests against a warned configuration produce exactly ONE line" do
    log =
      capture_log(fn ->
        plug_opts =
          init(
            enable_json_response: true,
            handler_opts: factory(),
            server_opts: [cache_defaults: {60_000, "public"}]
          )

        for _ <- 1..5 do
          conn =
            :post
            |> conn("http://localhost/", Jason.encode!(rpc("tools/list")))
            |> put_req_header("content-type", "application/json")
            |> put_req_header("accept", "application/json")
            |> put_req_header("origin", "http://localhost")
            |> put_req_header("mcp-protocol-version", @version)
            |> put_req_header("mcp-method", "tools/list")
            |> assign(:role, "PM")
            |> MCPPlug.call(plug_opts)

          assert conn.status == 200
        end
      end)

    assert count(log, @needle) == 1
  end

  # --- C3: the warning surfaces at RUNTIME via the documented Bandit shape ---

  test "C3: warning reaches the runtime log when started via Bandit plug: {Mod, opts}" do
    port = free_port()

    log =
      capture_log(fn ->
        {:ok, bandit} =
          Bandit.start_link(
            plug:
              {MCPPlug,
               [
                 server_mod: StatelessHandler,
                 handler_opts: factory(),
                 server_opts: [cache_defaults: {60_000, "public"}]
               ]},
            port: port,
            ip: {127, 0, 0, 1},
            startup_log: false
          )

        # init/1 runs during server startup (runtime), before any request.
        Process.exit(bandit, :normal)
      end)

    assert log =~ @needle
  end

  defp rpc(method),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => %{"_meta" => @meta}}

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
