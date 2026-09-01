defmodule MCP.Server.CallbackRuntime do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        MCP.Server.CallbackExecutor,
        {Task.Supervisor, name: MCP.Server.CallbackTaskSupervisor}
      ],
      strategy: :rest_for_one
    )
  end
end
