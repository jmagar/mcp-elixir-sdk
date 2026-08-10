defmodule MCPElixirSDK.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {MCP.Transport.StreamableHTTP.LegacySessionManager,
       name: MCP.Transport.StreamableHTTP.LegacySessionManager}
    ]

    opts = [strategy: :one_for_one, name: MCPElixirSDK.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
