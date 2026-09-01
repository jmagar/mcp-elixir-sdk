defmodule MCP.Client.ServerResponseDelivery do
  @moduledoc false

  @spec start(GenServer.server(), module(), pid(), map(), pos_integer()) ::
          {:ok, reference(), map()} | {:error, term()}
  def start(supervisor, transport_module, transport_pid, message, timeout) do
    owner = self()
    ref = make_ref()

    case Task.Supervisor.start_child(supervisor, fn ->
           result = transport_module.send_message(transport_pid, message)
           send(owner, {:server_response_delivery_result, ref, result})
         end) do
      {:ok, pid} ->
        timer = Process.send_after(owner, {:server_response_delivery_timeout, ref}, timeout)

        {:ok, ref, %{task_pid: pid, monitor_ref: Process.monitor(pid), timeout_ref: timer}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec cancel(GenServer.server(), map()) :: :ok
  def cancel(supervisor, delivery) do
    Process.cancel_timer(delivery.timeout_ref)
    Process.demonitor(delivery.monitor_ref, [:flush])
    _ = Task.Supervisor.terminate_child(supervisor, delivery.task_pid)
    :ok
  end
end
