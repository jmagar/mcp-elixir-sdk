defmodule MCP.Test.LegacySessionCapturePlug do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET"} = conn, _opts), do: Plug.Conn.send_resp(conn, 404, "")

  def call(%Plug.Conn{method: "DELETE"} = conn, _opts), do: Plug.Conn.send_resp(conn, 200, "")

  def call(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    message = Jason.decode!(body)
    send(Keyword.fetch!(opts, :test_pid), {:legacy_captured_request, conn.req_headers, message})

    cond do
      message["method"] == "server/discover" ->
        response = %{
          "jsonrpc" => "2.0",
          "id" => message["id"],
          "error" => %{"code" => -32_601, "message" => "Method not found"}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(response))

      message["method"] == "initialize" ->
        response = %{
          "jsonrpc" => "2.0",
          "id" => message["id"],
          "result" => %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "serverInfo" => %{"name" => "legacy", "version" => "1.0.0"}
          }
        }

        conn
        |> Plug.Conn.put_resp_header("mcp-session-id", "legacy-session")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))

      true ->
        Plug.Conn.send_resp(conn, 202, "")
    end
  end
end
