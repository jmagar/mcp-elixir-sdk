defmodule MCP.Transport.StreamableHTTPStatelessTest do
  @moduledoc """
  MES-9 — the stateless Streamable-HTTP transport: no handshake, no session,
  no affinity. Covers the request/response lifecycle, routing headers
  (SEP-2243), localhost/Origin enforcement (AC7 re-homed from the MES-5 AC
  suite), per-request identity threading (MC-2/MC-3/MC-4 over real HTTP), the
  MRTR round-trip (SEP-2322), and the DoD **two-instance / no-affinity smoke**.
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

  # --- helpers ---

  defp opts(extra \\ []) do
    MCPPlug.init([server_mod: StatelessHandler, enable_json_response: true] ++ extra)
  end

  defp rpc(method, params),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp post(plug_opts, message, headers \\ [], mutate \\ & &1) do
    base =
      :post
      |> conn("http://localhost/", Jason.encode!(message))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> put_req_header("origin", "http://localhost")

    base =
      message
      |> standard_headers()
      |> Enum.reduce(base, fn {k, v}, c -> put_req_header(c, k, v) end)

    headers
    |> Enum.reduce(base, fn {k, v}, c -> put_req_header(c, k, v) end)
    |> mutate.()
    |> MCPPlug.call(plug_opts)
  end

  defp raw_post(plug_opts, message, headers) do
    :post
    |> conn("http://localhost/", Jason.encode!(message))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put_req_header("origin", "http://localhost")
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
    end)
    |> MCPPlug.call(plug_opts)
  end

  defp result(conn), do: conn.resp_body |> Jason.decode!() |> Map.get("result")
  defp error(conn), do: conn.resp_body |> Jason.decode!() |> Map.get("error")
  defp with_meta(params), do: Map.put(params, "_meta", @meta)

  defp standard_headers(message) do
    method = Map.get(message, "method")
    params = Map.get(message, "params", %{})
    version = get_in(params, ["_meta", "io.modelcontextprotocol/protocolVersion"])

    []
    |> maybe_header("mcp-protocol-version", version)
    |> maybe_header("mcp-method", method)
    |> maybe_header("mcp-name", routing_target(method, params))
  end

  defp routing_target("tools/call", params), do: Map.get(params, "name")
  defp routing_target("prompts/get", params), do: Map.get(params, "name")
  defp routing_target("resources/read", params), do: Map.get(params, "uri")
  defp routing_target(_method, _params), do: nil

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, name, value), do: [{name, value} | headers]

  # --- lifecycle (no handshake, no session) ---

  test "server/discover returns the schema-shaped result after the version gate" do
    conn = post(opts(), rpc("server/discover", with_meta(%{})))
    r = result(conn)
    assert conn.status == 200
    assert r["supportedVersions"] == [@version]
    assert r["resultType"] == "complete"
    assert r["_meta"]["io.modelcontextprotocol/serverInfo"]["name"]
  end

  test "tools/list then tools/call work directly, no initialize first" do
    list = post(opts(), rpc("tools/list", with_meta(%{}))) |> result()
    assert Enum.any?(list["tools"], &(&1["name"] == "whoami"))
    assert list["resultType"] == "complete"

    call =
      post(opts(), rpc("tools/call", with_meta(%{"name" => "whoami", "arguments" => %{}})))
      |> result()

    assert call["resultType"] == "complete"
    assert hd(call["content"])["text"] == ""
  end

  test "list/read results carry caching hints (ttlMs/cacheScope)" do
    r = post(opts(), rpc("tools/list", with_meta(%{}))) |> result()
    assert r["ttlMs"] == 0
    assert r["cacheScope"] == "public"
  end

  test "a request without required metadata fails as invalid params before header validation" do
    conn = post(opts(), rpc("tools/call", %{"name" => "whoami"}))
    assert conn.status == 400
    assert error(conn)["code"] == -32_602
  end

  test "legacy methods cannot be mixed into a 2026 stateless request" do
    initialize = post(opts(), rpc("initialize", with_meta(%{})))
    assert initialize.status == 404
    assert error(initialize)["code"] == -32_601
    assert error(post(opts(), rpc("ping", with_meta(%{}))))["code"] == -32_601

    assert error(post(opts(), rpc("logging/setLevel", with_meta(%{"level" => "info"}))))[
             "code"
           ] == -32_601
  end

  # --- routing headers (SEP-2243) ---

  test "matching Mcp-Method routes normally; a mismatch is rejected (-32020)" do
    ok = post(opts(), rpc("tools/list", with_meta(%{})), [{"mcp-method", "tools/list"}])
    assert ok.status == 200

    bad = post(opts(), rpc("tools/list", with_meta(%{})), [{"mcp-method", "resources/list"}])
    assert error(bad)["code"] == -32_020
  end

  test "Mcp-Name mismatch against params.name is rejected (-32020)" do
    msg = rpc("tools/call", with_meta(%{"name" => "whoami", "arguments" => %{}}))
    bad = post(opts(), msg, [{"mcp-name", "other"}])
    assert error(bad)["code"] == -32_020
  end

  test "required routing headers cannot be omitted" do
    message = rpc("tools/call", with_meta(%{"name" => "whoami", "arguments" => %{}}))

    for header <- ["mcp-protocol-version", "mcp-method", "mcp-name"] do
      conn = post(opts(), message, [], &delete_req_header(&1, header))

      assert conn.status == 400
      assert error(conn)["code"] == -32_020
      assert error(conn)["data"] =~ header
    end
  end

  test "Mcp-Protocol-Version must match the request metadata" do
    conn =
      post(opts(), rpc("tools/list", with_meta(%{})), [
        {"mcp-protocol-version", "2099-01-01"}
      ])

    assert conn.status == 400
    assert error(conn)["code"] == -32_020
  end

  test "an unknown non-date protocol version reaches negotiation" do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "not-a-date",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    message = rpc("tools/list", %{"_meta" => meta})

    conn = post(opts(), message)

    assert conn.status == 400
    assert error(conn)["code"] == -32_022
  end

  test "malformed JSON structures return controlled errors instead of crashing" do
    standard = [
      {"mcp-method", "tools/call"},
      {"mcp-protocol-version", @version}
    ]

    cases = [
      {[], standard},
      {%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => "scalar"},
       standard},
      {rpc("tools/list", %{"_meta" => "scalar"}),
       [{"mcp-method", "tools/list"}, {"mcp-protocol-version", @version}]}
    ]

    for {message, headers} <- cases do
      conn = raw_post(opts(), message, headers)
      assert conn.status == 400
      assert is_integer(error(conn)["code"])
    end
  end

  test "oversized request bodies are rejected without crashing" do
    conn =
      :post
      |> conn("http://localhost/", String.duplicate("x", 65))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> put_req_header("origin", "http://localhost")
      |> MCPPlug.call(opts(max_body_length: 64))

    assert conn.status == 413
    assert error(conn)["code"] == -32_600
  end

  test "rejects an invalid maximum body length at mount" do
    assert_raise ArgumentError, ~r/max_body_length/, fn -> opts(max_body_length: 0) end
  end

  test "scalar tool arguments return a controlled error" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "region" => %{"type" => "string", "x-mcp-header" => "Region"}
      }
    }

    message = rpc("tools/call", with_meta(%{"name" => "whoami", "arguments" => "scalar"}))

    conn =
      raw_post(opts(tool_schemas: %{"whoami" => schema}), message, [
        {"mcp-method", "tools/call"},
        {"mcp-name", "whoami"},
        {"mcp-protocol-version", @version}
      ])

    assert conn.status == 400
    assert is_integer(error(conn)["code"])
  end

  test "malformed JSON-RPC error responses are rejected without crashing" do
    message = %{"jsonrpc" => "2.0", "id" => 1, "error" => "scalar"}
    conn = raw_post(opts(), message, [])

    assert conn.status == 400
    assert error(conn)["code"] == -32_600
  end

  test "a well-formed but unsupported protocol version reaches dispatch" do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2099-01-01",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    message = rpc("tools/list", %{"_meta" => meta})

    conn = post(opts(), message)

    assert conn.status == 400
    assert error(conn)["code"] == -32_022
  end

  test "Mcp-Name decodes the Base64 sentinel before comparison" do
    message = rpc("resources/read", with_meta(%{"uri" => " padded "}))
    encoded = "=?base64?IHBhZGRlZCA=?="

    conn = post(opts(), message, [{"mcp-name", encoded}])

    assert conn.status == 200
    assert hd(result(conn)["contents"])["uri"] == " padded "
  end

  test "a plain value with only the Base64 sentinel prefix remains plain" do
    name = "=?base64?literal"
    message = rpc("resources/read", with_meta(%{"uri" => name}))

    conn = post(opts(), message, [{"mcp-name", name}])

    assert conn.status == 200
    assert hd(result(conn)["contents"])["uri"] == name
  end

  test "a malformed Base64-sentinel Mcp-Name is rejected even when its text matches" do
    malformed = "=?base64?not-valid!?="
    message = rpc("resources/read", with_meta(%{"uri" => malformed}))

    conn = post(opts(), message, [{"mcp-name", malformed}])

    assert conn.status == 400
    assert error(conn)["code"] == -32_020
  end

  test "JSON-RPC responses are not treated as requests requiring routing headers" do
    conn = post(opts(), %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})

    assert conn.status == 202
    assert conn.resp_body == ""
  end

  test "a recognized custom routing header is required and must match the tool argument" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "region" => %{"type" => "string", "x-mcp-header" => "Region"}
      }
    }

    plug_opts = opts(tool_schemas: %{"whoami" => schema})

    message =
      rpc(
        "tools/call",
        with_meta(%{"name" => "whoami", "arguments" => %{"region" => "us-east"}})
      )

    missing = post(plug_opts, message)
    mismatch = post(plug_opts, message, [{"mcp-param-region", "us-west"}])
    matching = post(plug_opts, message, [{"mcp-param-region", "us-east"}])

    assert missing.status == 400
    assert error(missing)["code"] == -32_020
    assert error(missing)["data"] =~ "mcp-param-region"
    assert mismatch.status == 400
    assert error(mismatch)["code"] == -32_020
    assert matching.status == 200
  end

  test "a malformed Base64-sentinel custom routing header is rejected" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "region" => %{"type" => "string", "x-mcp-header" => "Region"}
      }
    }

    message =
      rpc(
        "tools/call",
        with_meta(%{"name" => "whoami", "arguments" => %{"region" => "north"}})
      )

    conn =
      post(
        opts(tool_schemas: %{"whoami" => schema}),
        message,
        [{"mcp-param-region", "=?base64?not-valid!?="}]
      )

    assert conn.status == 400
    assert error(conn)["code"] == -32_020
  end

  test "custom routing headers decode nested values and compare integers numerically" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "route" => %{
          "type" => "object",
          "properties" => %{
            "region" => %{"type" => "string", "x-mcp-header" => "Region"}
          }
        },
        "fresh" => %{"type" => "boolean", "x-mcp-header" => "Fresh"},
        "limit" => %{"type" => "integer", "x-mcp-header" => "Limit"}
      }
    }

    message =
      rpc(
        "tools/call",
        with_meta(%{
          "name" => "whoami",
          "arguments" => %{"route" => %{"region" => "北"}, "fresh" => false, "limit" => 42}
        })
      )

    conn =
      post(opts(tool_schemas: %{"whoami" => schema}), message, [
        {"mcp-param-region", "=?base64?5YyX?="},
        {"mcp-param-fresh", "false"},
        {"mcp-param-limit", "042"}
      ])

    assert conn.status == 200
  end

  test "the tool-schema resolver runs after identity resolution" do
    test_pid = self()

    resolver = fn name, identity ->
      send(test_pid, {:schema_resolved, name, identity})

      %{
        "type" => "object",
        "properties" => %{
          "region" => %{"type" => "string", "x-mcp-header" => "Region"}
        }
      }
    end

    plug_opts =
      opts(
        handler_opts: fn conn -> [identity: conn.assigns[:role]] end,
        tool_schemas: resolver
      )

    message =
      rpc(
        "tools/call",
        with_meta(%{"name" => "whoami", "arguments" => %{"region" => "us-east"}})
      )

    conn =
      post(plug_opts, message, [{"mcp-param-region", "us-east"}], &assign(&1, :role, "PM"))

    assert conn.status == 200
    assert_receive {:schema_resolved, "whoami", "PM"}
  end

  # SEP-2243 (F1): for resources/read the Mcp-Name target is params.uri.
  test "resources/read — Mcp-Name is validated against params.uri (mismatch → -32020)" do
    msg = rpc("resources/read", with_meta(%{"uri" => "mem://res"}))

    bad = post(opts(), msg, [{"mcp-name", "other"}])
    assert error(bad)["code"] == -32_020

    ok = post(opts(), msg, [{"mcp-name", "mem://res"}])
    assert ok.status == 200
    assert hd(result(ok)["contents"])["uri"] == "mem://res"
  end

  # --- origin enforcement (AC7 re-homed) ---

  test "AC7 — non-localhost origin is rejected 403; the identity factory never runs" do
    test_pid = self()

    plug_opts =
      opts(
        handler_opts: fn _conn ->
          send(test_pid, :factory_ran)
          [identity: "PM"]
        end
      )

    conn =
      :post
      |> conn("http://localhost/", Jason.encode!(rpc("tools/list", with_meta(%{}))))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "http://evil.example")
      |> MCPPlug.call(plug_opts)

    assert conn.status == 403
    refute_receive :factory_ran, 200
  end

  test "AC7 — duplicate Origin or Host headers are rejected even when one value is localhost" do
    message = Jason.encode!(rpc("tools/list", with_meta(%{})))

    for headers <- [
          [{"origin", "http://evil.example"}, {"origin", "http://localhost"}],
          [{"host", "evil.example"}, {"host", "localhost"}]
        ] do
      conn =
        :post
        |> conn("http://localhost/", message)
        |> put_req_header("content-type", "application/json")

      conn = MCPPlug.call(%{conn | req_headers: headers ++ conn.req_headers}, opts())

      assert conn.status == 403
    end
  end

  # --- per-request identity (MC-2 / MC-3 / MC-4 over real HTTP) ---

  test "MC-2 — the factory resolves identity per request from conn.assigns" do
    plug_opts = opts(handler_opts: fn conn -> [identity: conn.assigns[:role]] end)

    conn =
      post(
        plug_opts,
        rpc("tools/call", with_meta(%{"name" => "whoami"})),
        [],
        &assign(&1, :role, "REVIEWER")
      )

    assert hd(result(conn)["content"])["text"] == "REVIEWER"
  end

  test "MC-4 — a tool-arg identity cannot override the pipeline identity" do
    plug_opts = opts(handler_opts: fn conn -> [identity: conn.assigns[:role]] end)

    conn =
      post(
        plug_opts,
        rpc(
          "tools/call",
          with_meta(%{"name" => "whoami_with_arg", "arguments" => %{"identity" => "spoof"}})
        ),
        [],
        &assign(&1, :role, "PM")
      )

    assert hd(result(conn)["content"])["text"] == "PM"
  end

  test "MC-3 — two interleaved requests each see their own identity (no leakage)" do
    plug_opts = opts(handler_opts: fn conn -> [identity: conn.assigns[:role]] end)

    call = fn role ->
      post(
        plug_opts,
        rpc("tools/call", with_meta(%{"name" => "whoami"})),
        [],
        &assign(&1, :role, role)
      )
    end

    assert hd(result(call.("PM"))["content"])["text"] == "PM"
    assert hd(result(call.("REVIEWER"))["content"])["text"] == "REVIEWER"
  end

  test "MC-6 — a factory that raises fails cleanly (-32603) with no handler invoked" do
    plug_opts = opts(handler_opts: fn _conn -> raise "boom secret=abc123" end)

    {conn, log} =
      with_log(fn ->
        post(plug_opts, rpc("tools/list", with_meta(%{})))
      end)

    assert conn.status == 500
    assert error(conn)["code"] == -32_603
    refute conn.resp_body =~ "abc123"
    assert log =~ "handler_opts factory failed"
  end

  # MC-6 regression (correction round 1): a collector that fails to START must
  # take the controlled internal-error path, NOT crash on an unguarded match.
  # Before the fix, `dispatch/5` did `{:ok, collector} = start_link()`, so an
  # {:error, _} start raised MatchError — MC-6 unsatisfied while the /plan and
  # AC5 claimed it satisfied. The `collector_start` seam makes Codex's manual
  # injection a permanent test (A7); shown FAILING against the unguarded match
  # and passing here.
  test "MC-6 — a collector that fails to start fails cleanly (-32603), no handler invoked" do
    plug_opts =
      opts(collector_start: fn -> {:error, :injected_collector_failure_secret} end)

    {conn, log} =
      with_log(fn ->
        post(plug_opts, rpc("tools/call", with_meta(%{"name" => "whoami"})))
      end)

    assert conn.status == 500
    assert error(conn)["code"] == -32_603
    # No handler ran: the response is the controlled error, not a tool result.
    refute conn.resp_body =~ "resultType"
    # The internal reason is logged server-side, never returned to the client.
    refute conn.resp_body =~ "injected_collector_failure_secret"
    assert log =~ "notification collector failed to start"
    assert log =~ "injected_collector_failure_secret"
  end

  # --- MRTR round-trip (SEP-2322) ---

  test "tools/call input-required → retry with requestState → completion" do
    first = post(opts(), rpc("tools/call", with_meta(%{"name" => "needs_input"}))) |> result()
    assert first["resultType"] == "input_required"
    assert first["requestState"] == "rs-token-1"
    assert is_map(first["inputRequests"])

    retry_params =
      with_meta(%{
        "name" => "needs_input",
        "arguments" => %{},
        "requestState" => first["requestState"],
        "inputResponses" => %{"name" => %{"name" => "Ada"}}
      })

    final = post(opts(), rpc("tools/call", retry_params)) |> result()
    assert final["resultType"] == "complete"
    assert hd(final["content"])["text"] == "hello Ada"
  end

  # --- transport errors ---

  test "DELETE requires the legacy version and session headers; parse error → -32700" do
    del =
      conn(:delete, "http://localhost/")
      |> put_req_header("origin", "http://localhost")
      |> MCPPlug.call(opts())

    assert del.status == 400
    assert error(del)["message"] == "Unsupported protocol version"

    bad =
      :post
      |> conn("http://localhost/", "not json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "http://localhost")
      |> MCPPlug.call(opts())

    assert bad.status == 400
    assert error(bad)["code"] == -32_700
  end

  # --- Ruling 7: no cross-request notification residue after a handler raises ---

  test "a raising handler leaves no notification residue for the next request (SSE)" do
    # SSE mode so notifications are flushed into the response body — exactly
    # where the leak was visible. Two calls in THIS process: request 1 (PM)
    # emits an identity-bearing notification then raises; request 2 (REVIEWER),
    # same process, must not receive PM's notification.
    plug_opts =
      MCPPlug.init(
        server_mod: StatelessHandler,
        enable_json_response: false,
        handler_opts: fn conn -> [identity: conn.assigns[:role]] end
      )

    failed =
      post(
        plug_opts,
        rpc("tools/call", with_meta(%{"name" => "emit_then_raise"})),
        [],
        &assign(&1, :role, "PM")
      )

    assert failed.status == 200
    assert failed.resp_body =~ "handler callback failed"

    conn2 =
      post(
        plug_opts,
        rpc("tools/call", with_meta(%{"name" => "whoami"})),
        [],
        &assign(&1, :role, "REVIEWER")
      )

    assert conn2.status == 200
    # No residue: neither the notification frame nor PM's identity leaks.
    refute conn2.resp_body =~ "notifications/message"
    refute conn2.resp_body =~ "PM"
    # Sanity: request 2 still gets its own result.
    assert conn2.resp_body =~ "REVIEWER"
  end

  test "raising, throwing, exiting, and malformed handlers return internal errors" do
    for name <- ["emit_then_raise", "throwing", "exiting", "invalid_return"] do
      conn = post(opts(), rpc("tools/call", with_meta(%{"name" => name})))
      assert conn.status == 200
      assert error(conn)["code"] == -32_603
      assert error(conn)["data"] == "handler callback failed"
    end
  end

  # --- DoD: two-instance / no-affinity smoke ---

  describe "two-instance / no-affinity smoke (DoD)" do
    setup do
      {url1, b1} = start_instance()
      {url2, b2} = start_instance()
      on_exit(fn -> for b <- [b1, b2], do: Process.exit(b, :normal) end)
      %{urls: [url1, url2]}
    end

    test "interleaving requests round-robin across two stateless instances succeeds identically",
         %{urls: urls} do
      # No shared session state between the two Bandit instances; every request
      # is self-contained. Round-robin the sequence across both and assert
      # identical results — proving there is no session affinity.
      sequence = [
        {"server/discover", with_meta(%{})},
        {"tools/list", with_meta(%{})},
        {"tools/call", with_meta(%{"name" => "whoami", "arguments" => %{}})},
        {"resources/read", with_meta(%{"uri" => "mem://res"})}
      ]

      results =
        sequence
        |> Enum.with_index()
        |> Enum.map(fn {{method, params}, i} ->
          url = Enum.at(urls, rem(i, 2))
          http_post(url, method, params)
        end)

      assert Enum.all?(results, &(&1.status == 200))

      # Same request on both instances yields the same body (no affinity).
      a = http_post(Enum.at(urls, 0), "tools/list", with_meta(%{}))
      b = http_post(Enum.at(urls, 1), "tools/list", with_meta(%{}))
      assert a.body["result"] == b.body["result"]
    end
  end

  defp start_instance do
    port = free_port()
    plug_opts = MCPPlug.init(server_mod: StatelessHandler, enable_json_response: true)

    {:ok, bandit} =
      Bandit.start_link(plug: {MCPPlug, plug_opts}, port: port, ip: {127, 0, 0, 1})

    {"http://127.0.0.1:#{port}", bandit}
  end

  defp http_post(url, method, params) do
    message = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
    body = Jason.encode!(message)

    headers =
      [
        {"content-type", "application/json"},
        {"accept", "application/json"},
        {"origin", "http://localhost"}
      ] ++ standard_headers(message)

    {:ok, resp} = Req.post(url, body: body, headers: headers)
    resp
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
