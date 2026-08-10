defmodule MCP.Test.HTTPResponsePlug do
  @moduledoc false

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    {:ok, _body, conn} = Plug.Conn.read_body(conn)

    conn
    |> Plug.Conn.put_resp_content_type(Keyword.get(opts, :content_type, "application/json"))
    |> Plug.Conn.send_resp(
      Keyword.fetch!(opts, :status),
      Jason.encode!(Keyword.fetch!(opts, :body))
    )
  end
end
