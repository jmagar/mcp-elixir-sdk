#!/usr/bin/env elixir

Code.require_file("apps_browser_handler.ex", Path.dirname(__ENV__.file))

port = System.get_env("MCP_APPS_INTEROP_PORT", "43101") |> String.to_integer()

defmodule MCP.Conformance.AppsBrowserPlug do
  @behaviour Plug

  @impl Plug
  def init({module, opts}), do: {module, module.init(opts)}

  @impl Plug
  def call(%Plug.Conn{request_path: "/health"} = conn, _mcp_plug),
    do: Plug.Conn.send_resp(conn, 200, "ok")

  def call(conn, {module, opts}), do: module.call(conn, opts)
end

plug =
  MCP.Transport.StreamableHTTP.Plug.new(
    server_mod: MCP.Conformance.AppsBrowserHandler,
    server_opts: [
      server_info: %{name: "mcp-elixir-sdk-apps-interop", version: "1.0.0"},
      extensions: MCP.Apps.extensions()
    ],
    protocol_version: "2026-07-28",
    enable_json_response: true,
    allowed_origins: ["http://127.0.0.1:6274"]
  )

{:ok, _server} =
  Bandit.start_link(
    plug: {MCP.Conformance.AppsBrowserPlug, plug},
    port: port,
    ip: {127, 0, 0, 1}
  )

IO.puts("MCP Apps browser fixture ready on http://127.0.0.1:#{port}/mcp")
Process.sleep(:infinity)
