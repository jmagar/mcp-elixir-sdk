defmodule MCP.Test.RoutingRecoveryPlug do
  @moduledoc false

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    message = Jason.decode!(body)

    case message["method"] do
      "server/discover" ->
        respond(conn, 200, message["id"], discover_result())

      "tools/list" ->
        header =
          Agent.get_and_update(opts[:state], fn count ->
            {if(count == 0, do: "Region", else: "Zone"), count + 1}
          end)

        respond(conn, 200, message["id"], %{"tools" => [tool(header)]})

      "tools/call" ->
        if Plug.Conn.get_req_header(conn, "mcp-param-zone") == ["east"] do
          respond(conn, 200, message["id"], %{"content" => [], "resultType" => "complete"})
        else
          error(conn, 400, message["id"], "missing mcp-param-zone header")
        end
    end
  end

  defp discover_result do
    %{
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{"tools" => %{}},
      "resultType" => "complete",
      "ttlMs" => 0,
      "cacheScope" => "public",
      "_meta" => %{
        "io.modelcontextprotocol/serverInfo" => %{"name" => "recovery", "version" => "1"}
      }
    }
  end

  defp tool(header) do
    %{
      "name" => "weather",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "region" => %{"type" => "string", "x-mcp-header" => header}
        }
      }
    }
  end

  defp respond(conn, status, id, result) do
    send_json(conn, status, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp error(conn, status, id, data) do
    send_json(conn, status, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_020, "message" => "Header mismatch", "data" => data}
    })
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
