defmodule MCP.Test.RequestCapturePlug do
  @moduledoc false

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    send(Keyword.fetch!(opts, :test_pid), {
      :captured_request,
      conn.req_headers,
      Jason.decode!(body)
    })

    Plug.Conn.send_resp(conn, 202, "")
  end
end
