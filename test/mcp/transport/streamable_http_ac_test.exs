defmodule MCP.Transport.StreamableHTTP.ACTest do
  @moduledoc """
  MES-10 — the ported EMFA acceptance criteria AC1–AC8 (+ AC3′) and the
  identity-invariant **spoof-vector sweep**, as end-to-end tests over **real
  HTTP** (Bandit + `Req`) through a realistic authenticated pipeline.

  The harness (`MCP.Test.AuthedMCPPlug`) is `MCP.Test.AuthPlug` → the MCP Plug:
  an upstream auth Plug converts the `x-test-role` credential into
  `conn.assigns[:role]` (the **authenticated** channel), and the MCP identity
  factory reads that assign. Spoof tests plant a competing identity value in
  **every model-controlled channel** — tool arguments, `prompts/get` arguments,
  `_meta`, raw request headers, and the MRTR `requestState`/`inputResponses`
  continuation — and assert the pipeline identity always wins.

  Lineage: this file previously held the MES-5 handshake-anchored AC1–AC8
  (retired `:mes10_retired` by the MES-9 ledger split). MES-10 rewrites it
  stateless and **closes** that ledger line — the file that held the retired
  ACs is the file that ports them. AC7 (localhost/Origin enforcement; factory
  not invoked on reject) is proven at plug-unit level with a `refute_receive`
  in `streamable_http_stateless_test.exs`; this suite adds an acceptance-level
  403 parity assertion only.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MCP.Test.{AuthedMCPPlug, StatelessHandler}
  alias MCP.Transport.StreamableHTTP.Plug, as: MCPPlug

  @version "2026-07-28"

  # --- harness ---

  # The standard instance: a per-request factory reading the authenticated
  # `conn.assigns[:role]`. Two are started so AC6′ can round-robin across
  # independent, share-nothing instances.
  setup_all do
    role_factory = fn conn -> [identity: conn.assigns[:role]] end
    u1 = start_instance(handler_opts: role_factory)
    u2 = start_instance(handler_opts: role_factory)
    %{std: u1, std2: u2}
  end

  defp start_instance(extra_opts) do
    port = free_port()

    mcp_opts =
      Keyword.merge([server_mod: StatelessHandler, enable_json_response: true], extra_opts)

    {:ok, bandit} =
      Bandit.start_link(plug: {AuthedMCPPlug, mcp_opts}, port: port, ip: {127, 0, 0, 1})

    on_exit(fn -> Process.exit(bandit, :normal) end)
    "http://127.0.0.1:#{port}"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp with_meta(params, extra_meta \\ %{}) do
    meta =
      Map.merge(
        %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        extra_meta
      )

    Map.put(params, "_meta", meta)
  end

  # POST a JSON-RPC message over real HTTP. `:role` sets the authenticated
  # `x-test-role` header; `:headers` adds arbitrary (model-reachable) headers;
  # `:origin` overrides the default localhost origin.
  defp post(url, method, params, opts) do
    role = Keyword.get(opts, :role)
    origin = Keyword.get(opts, :origin, "http://localhost")

    headers =
      [
        {"content-type", "application/json"},
        {"accept", "application/json"},
        {"origin", origin},
        {"mcp-protocol-version",
         get_in(params, ["_meta", "io.modelcontextprotocol/protocolVersion"])},
        {"mcp-method", method}
      ] ++
        routing_name_header(method, params) ++
        if(role, do: [{"x-test-role", role}], else: []) ++
        Keyword.get(opts, :headers, [])

    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    {:ok, resp} = Req.post(url, body: body, headers: headers)
    resp
  end

  defp result(resp), do: resp.body["result"]
  defp error(resp), do: resp.body["error"]
  defp tool_text(resp), do: result(resp)["content"] |> hd() |> Map.get("text")

  defp routing_name_header(method, params) do
    target =
      case method do
        "tools/call" -> Map.get(params, "name")
        "prompts/get" -> Map.get(params, "name")
        "resources/read" -> Map.get(params, "uri")
        _method -> nil
      end

    if target, do: [{"mcp-name", target}], else: []
  end

  # ======================================================================
  # AC PORT MATRIX — AC1–AC8 + AC3′
  # ======================================================================

  # --- AC1 — static handler_opts identity threads per request ---

  test "AC1 — static handler_opts identity threads per request" do
    url = start_instance(handler_opts: [identity: "PM"])
    # Even with a competing authenticated role, the static identity is the
    # constant the SDK uses (the static form ignores conn).
    assert tool_text(post(url, "tools/call", with_meta(%{"name" => "whoami"}), role: "REVIEWER")) ==
             "PM"
  end

  # --- AC2 — per-request factory reads conn.assigns ---

  test "AC2 — factory reads conn.assigns per request", %{std: url} do
    assert tool_text(
             post(url, "tools/call", with_meta(%{"name" => "whoami"}), role: "CODE_CREATOR")
           ) ==
             "CODE_CREATOR"
  end

  # --- AC3 ★ — a tools/call identity arg is ignored; pipeline wins (real HTTP) ---

  test "AC3 — tools/call identity arg is ignored; pipeline wins", %{std: url} do
    params = with_meta(%{"name" => "whoami_with_arg", "arguments" => %{"identity" => "PM-SPOOF"}})
    assert tool_text(post(url, "tools/call", params, role: "REVIEWER")) == "REVIEWER"
  end

  # --- AC3′ ★ (NEW) — a prompts/get identity arg is ignored; pipeline wins ---

  test "AC3' — prompts/get identity arg is ignored; pipeline wins", %{std: url} do
    params = with_meta(%{"name" => "who", "arguments" => %{"identity" => "PM-SPOOF"}})
    resp = post(url, "prompts/get", params, role: "REVIEWER")
    text = result(resp)["messages"] |> hd() |> get_in(["content", "text"])
    assert text == "REVIEWER"
  end

  # --- AC4 — absent handler_opts is backward-compatible (empty identity) ---

  test "AC4 — absent handler_opts is backward-compatible (empty identity)" do
    url = start_instance([])

    assert tool_text(post(url, "tools/call", with_meta(%{"name" => "whoami"}), role: "REVIEWER")) ==
             ""
  end

  # --- AC5 — identity is per-request fresh, never sticky ---

  test "AC5 — identity is per-request fresh; a changed credential is reflected next request",
       %{std: url} do
    # No initialize/session to bind at: each request resolves its own identity.
    assert tool_text(post(url, "tools/call", with_meta(%{"name" => "whoami"}), role: "PM")) ==
             "PM"

    assert tool_text(post(url, "tools/call", with_meta(%{"name" => "whoami"}), role: "REVIEWER")) ==
             "REVIEWER"
  end

  # --- AC6′ ★ — interleaved callers across two instances never leak identity ---

  test "AC6' — interleaved authenticated callers across two instances never leak identity",
       %{std: u1, std2: u2} do
    # Round-robin two instances with interleaved principals; each request must
    # observe only its own identity (no session/affinity, no shared store).
    seq = [{u1, "PM"}, {u2, "REVIEWER"}, {u1, "REVIEWER"}, {u2, "PM"}, {u1, "PO"}, {u2, "CC"}]

    for {url, role} <- seq do
      assert tool_text(post(url, "tools/call", with_meta(%{"name" => "whoami"}), role: role)) ==
               role
    end
  end

  # --- AC7 — non-localhost origin rejected over real HTTP (parity) ---

  test "AC7 — non-localhost origin is rejected 403 (acceptance parity)", %{std: url} do
    resp =
      post(url, "tools/call", with_meta(%{"name" => "whoami"}),
        role: "PM",
        origin: "http://evil.example"
      )

    assert resp.status == 403
  end

  # --- AC8 — factory raise / non-keyword → clean -32603, nothing leaked ---

  test "AC8 — a factory that raises fails cleanly (-32603); the secret never leaks" do
    url = start_instance(handler_opts: fn _conn -> raise "boom secret=xyz789" end)

    {resp, _log} =
      with_log(fn -> post(url, "tools/call", with_meta(%{"name" => "whoami"}), role: "PM") end)

    assert resp.status == 500
    assert error(resp)["code"] == -32_603
    refute Jason.encode!(resp.body) =~ "xyz789"
  end

  test "AC8 — a factory that returns a non-keyword fails cleanly (-32603)" do
    url = start_instance(handler_opts: fn _conn -> :not_a_keyword end)

    {resp, _log} =
      with_log(fn -> post(url, "tools/call", with_meta(%{"name" => "whoami"}), role: "PM") end)

    assert resp.status == 500
    assert error(resp)["code"] == -32_603
  end

  test "AC8 — a static non-keyword handler_opts fails fast at init (ArgumentError)" do
    # Preserves the MES-3 case-8 fail-fast (handler_opts_test.exs) at the SDK
    # boundary: bad static config never reaches a request.
    assert_raise ArgumentError, ~r/handler_opts must be a keyword list/, fn ->
      MCPPlug.init(server_mod: StatelessHandler, handler_opts: [1, 2, 3])
    end
  end

  # ======================================================================
  # HARDENING — spoof-vector sweep (D2 §4.2). Each vector: plant a competing
  # identity in the model-controlled channel; assert the pipeline value wins.
  # ======================================================================

  # Vector: tool-call arguments — covered by AC3 (tools/call) + AC3′ (prompts/get).

  # Vector: _meta entries (incl. the self-declared clientInfo label).
  test "spoof — a _meta clientInfo/identity value is ignored; pipeline wins", %{std: url} do
    spoof_meta = %{
      "io.modelcontextprotocol/clientInfo" => %{"name" => "PM-SPOOF"},
      "identity" => "PM-SPOOF"
    }

    params = with_meta(%{"name" => "whoami"}, spoof_meta)
    assert tool_text(post(url, "tools/call", params, role: "REVIEWER")) == "REVIEWER"
  end

  # Vector: model-reachable raw request headers (not the authenticated assign).
  test "spoof — a body-reachable identity-looking header does not change identity", %{std: url} do
    headers = [{"x-user", "PM-SPOOF"}, {"identity", "PM-SPOOF"}]
    params = with_meta(%{"name" => "whoami"})

    assert tool_text(post(url, "tools/call", params, role: "REVIEWER", headers: headers)) ==
             "REVIEWER"
  end

  # Vector: MRTR continuation (SEP-2567 state handle). requestState +
  # inputResponses are model-passed; identity must be re-resolved from THIS
  # request's pipeline on the retry, never taken from the continuation.
  test "spoof — MRTR retry with planted identity is ignored; identity re-resolved fresh",
       %{std: url} do
    first = post(url, "tools/call", with_meta(%{"name" => "needs_input_id"}), role: "PM")
    assert result(first)["resultType"] == "input_required"
    assert result(first)["requestState"] == "rs-token-id"

    retry_params =
      with_meta(%{
        "name" => "needs_input_id",
        "arguments" => %{},
        "requestState" => result(first)["requestState"],
        "inputResponses" => %{
          "identity" => %{"name" => "x", "identity" => "PM-SPOOF"}
        }
      })

    # Retry carries a DIFFERENT authenticated role than the first request:
    # completion must echo the retry's re-resolved identity (REVIEWER),
    # neither the first request's PM nor the planted PM-SPOOF.
    final = post(url, "tools/call", retry_params, role: "REVIEWER")
    assert result(final)["resultType"] == "complete"
    assert tool_text(final) == "REVIEWER"
  end

  # Vector: caches shared across requests/instances — the shipped default is
  # no-store (ttlMs 0), so nothing is cached to leak. (AC6′ proves no
  # cross-request/instance identity leakage directly.)
  test "default caching policy is no-store (ttlMs 0)", %{std: url} do
    r = result(post(url, "tools/list", with_meta(%{}), role: "PM"))
    assert r["ttlMs"] == 0
    assert r["cacheScope"] == "public"
  end

  # §3.2 — identity is server-internal and never serialized into the response
  # envelope unless a handler deliberately echoes it. The `silent` tool never
  # touches identity, so a sentinel principal must appear nowhere in the body.
  test "identity never crosses the wire (envelope carries no identity)", %{std: url} do
    sentinel = "SENTINEL-PRINCIPAL-9f3a"
    resp = post(url, "tools/call", with_meta(%{"name" => "silent"}), role: sentinel)
    assert tool_text(resp) == "ok"
    refute Jason.encode!(resp.body) =~ sentinel
  end
end
