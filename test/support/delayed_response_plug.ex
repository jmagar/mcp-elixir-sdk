defmodule MCP.Test.DelayedResponsePlug do
  @moduledoc false

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    message = Jason.decode!(body)

    if message["id"] == Keyword.fetch!(opts, :delayed_id) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:delayed_request_started, self()})

      receive do
        :release_delayed_request -> :ok
      end
    end

    response = %{"jsonrpc" => "2.0", "id" => message["id"], "result" => %{}}

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(response))
  end
end
