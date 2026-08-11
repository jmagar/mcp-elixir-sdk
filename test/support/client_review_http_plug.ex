defmodule MCP.Test.ClientReviewHTTPPlug do
  @moduledoc false
  @behaviour Plug

  @legacy_version "2025-11-25"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "DELETE"} = conn, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:client_review_delete, self()})

    receive do
      :release_delete -> Plug.Conn.send_resp(conn, 204, "")
    after
      2_000 -> Plug.Conn.send_resp(conn, 204, "")
    end
  end

  def call(%Plug.Conn{method: "GET"} = conn, opts) do
    case Keyword.get(opts, :legacy_get_status) do
      nil ->
        if Keyword.get(opts, :stream?),
          do: stream(conn, opts),
          else: Plug.Conn.send_resp(conn, 404, "")

      status ->
        Plug.Conn.send_resp(conn, status, "")
    end
  end

  def call(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    message = Jason.decode!(body)
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:client_review_http_post, conn.req_headers, message})

    handle_post(conn, message, opts)
  end

  defp handle_post(conn, message, opts) do
    case message["method"] do
      "server/discover" ->
        discover_response(conn, message, opts)

      "initialize" ->
        update_recovery_counter(opts, :initializes)

        conn
        |> Plug.Conn.put_resp_header("mcp-session-id", "review-session")
        |> respond(200, %{
          "jsonrpc" => "2.0",
          "id" => message["id"],
          "result" => %{
            "protocolVersion" => @legacy_version,
            "capabilities" => %{},
            "serverInfo" => %{"name" => "review", "version" => "1"}
          }
        })

      "tools/list" ->
        if Keyword.has_key?(opts, :recovery),
          do: recovery_tools_response(conn, message, opts),
          else: default_post_response(conn, message, opts)

      "subscriptions/listen" ->
        subscription_response(conn, message, opts)

      _method ->
        default_post_response(conn, message, opts)
    end
  end

  defp subscription_response(conn, message, opts) do
    cond do
      Keyword.has_key?(opts, :subscription_status) ->
        Plug.Conn.send_resp(
          conn,
          Keyword.fetch!(opts, :subscription_status),
          Keyword.fetch!(opts, :subscription_body)
        )

      Keyword.has_key?(opts, :subscription_body) ->
        stream_body(conn, Keyword.fetch!(opts, :subscription_body))

      true ->
        default_post_response(conn, message, opts)
    end
  end

  defp discover_response(conn, message, opts) do
    if Keyword.get(opts, :downgrade?) do
      respond(conn, 400, %{
        "jsonrpc" => "2.0",
        "id" => message["id"],
        "error" => %{
          "code" => -32_022,
          "message" => "Unsupported protocol version",
          "data" => %{"supported" => [@legacy_version]}
        }
      })
    else
      default_post_response(conn, message, opts)
    end
  end

  defp default_post_response(conn, message, opts) do
    if Keyword.get(opts, :bind_non_initialize?) do
      conn
      |> Plug.Conn.put_resp_header("mcp-session-id", "must-not-bind")
      |> respond(200, %{"jsonrpc" => "2.0", "id" => message["id"], "result" => %{}})
    else
      Plug.Conn.send_resp(conn, 202, "")
    end
  end

  defp stream(conn, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)

    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    body =
      Keyword.get(
        opts,
        :stream_body,
        "data: #{Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/progress", "params" => %{"progress" => 1}})}\n\n"
      )

    {:ok, conn} = Plug.Conn.chunk(conn, body)

    send(test_pid, {:client_review_stream_chunked, self()})

    receive do
      :release_stream -> conn
    after
      2_000 -> conn
    end
  end

  defp stream_body(conn, body) do
    conn =
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

    {:ok, conn} = Plug.Conn.chunk(conn, body)
    conn
  end

  defp recovery_tools_response(conn, message, opts) do
    count = update_recovery_counter(opts, :tools)

    if Keyword.fetch!(opts, :recovery) == :always or count == 1 do
      respond(conn, 404, %{
        "jsonrpc" => "2.0",
        "id" => message["id"],
        "error" => %{"code" => -32_001, "message" => "Session expired"}
      })
    else
      respond(conn, 200, %{
        "jsonrpc" => "2.0",
        "id" => message["id"],
        "result" => %{"tools" => []}
      })
    end
  end

  defp update_recovery_counter(opts, key) do
    case Keyword.get(opts, :recovery_agent) do
      nil ->
        0

      agent ->
        Agent.get_and_update(agent, fn counters ->
          count = Map.get(counters, key, 0) + 1
          {count, Map.put(counters, key, count)}
        end)
    end
  end

  defp respond(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
