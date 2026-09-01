defmodule MCP.Client.ServerRequestCoordinator do
  @moduledoc false

  require Logger

  alias MCP.Client.{ServerRequestResponse, ServerResponseDelivery}
  alias MCP.Protocol.Error

  defstruct callbacks: %{}, deliveries: %{}

  def new, do: %__MODULE__{}
  def put_callback(%__MODULE__{} = state, ref, value), do: put_in(state.callbacks[ref], value)
  def put_delivery(%__MODULE__{} = state, ref, value), do: put_in(state.deliveries[ref], value)

  def pop_callback(%__MODULE__{} = state, ref) do
    {value, callbacks} = Map.pop(state.callbacks, ref)
    {value, %{state | callbacks: callbacks}}
  end

  def pop_delivery(%__MODULE__{} = state, ref) do
    {value, deliveries} = Map.pop(state.deliveries, ref)
    {value, %{state | deliveries: deliveries}}
  end

  def callback_by_monitor(%__MODULE__{} = state, monitor_ref),
    do: by_monitor(state.callbacks, monitor_ref)

  def delivery_by_monitor(%__MODULE__{} = state, monitor_ref),
    do: by_monitor(state.deliveries, monitor_ref)

  def each_callback(%__MODULE__{} = state, fun), do: Enum.each(state.callbacks, fun)
  def each_delivery(%__MODULE__{} = state, fun), do: Enum.each(state.deliveries, fun)

  def callback_result(client, ref, response, deliver) do
    case pop_callback(client.server_requests, ref) do
      {nil, _} ->
        {:ignored, client}

      {callback, requests} ->
        Process.cancel_timer(callback.timeout_ref)
        Process.demonitor(callback.monitor_ref, [:flush])
        {:handled, deliver.(%{client | server_requests: requests}, callback.id, response)}
    end
  end

  def callback_timeout(client, ref, supervisor, deliver) do
    case pop_callback(client.server_requests, ref) do
      {nil, _} ->
        {:ignored, client}

      {callback, requests} ->
        Process.demonitor(callback.monitor_ref, [:flush])
        _ = Task.Supervisor.terminate_child(supervisor, callback.pid)

        {:handled,
         deliver.(
           %{client | server_requests: requests},
           callback.id,
           {:error, Error.internal_error("client request handler timed out")}
         )}
    end
  end

  def delivery_result(client, ref, result) do
    case pop_delivery(client.server_requests, ref) do
      {nil, _} ->
        {:ignored, client}

      {delivery, requests} ->
        Process.cancel_timer(delivery.timeout_ref)
        Process.demonitor(delivery.monitor_ref, [:flush])
        log_delivery(delivery.id, result)
        {:handled, %{client | server_requests: requests}}
    end
  end

  def delivery_timeout(client, ref, supervisor) do
    case pop_delivery(client.server_requests, ref) do
      {nil, _} ->
        {:ignored, client}

      {delivery, requests} ->
        Process.demonitor(delivery.monitor_ref, [:flush])
        _ = Task.Supervisor.terminate_child(supervisor, delivery.task_pid)

        Logger.error(
          "MCP client server-request response delivery timed out id=#{inspect(delivery.id)}"
        )

        {:handled, %{client | server_requests: requests}}
    end
  end

  def start_callback(supervisor, owner, handlers, request, timeout) do
    handler = Map.get(handlers, request.method)
    ref = make_ref()

    case Task.Supervisor.start_child(supervisor, fn ->
           response = invoke(handler, request.method, request.params)
           send(owner, {:server_request_callback_result, ref, response})
         end) do
      {:ok, pid} ->
        callback = %{
          id: request.id,
          pid: pid,
          monitor_ref: Process.monitor(pid),
          timeout_ref: Process.send_after(owner, {:server_request_callback_timeout, ref}, timeout)
        }

        {:ok, ref, callback}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def start_delivery(supervisor, transport_module, transport_pid, id, response, timeout) do
    message = ServerRequestResponse.encode(id, response)

    case ServerResponseDelivery.start(
           supervisor,
           transport_module,
           transport_pid,
           message,
           timeout
         ) do
      {:ok, ref, delivery} -> {:ok, ref, Map.put(delivery, :id, id)}
      {:error, reason} -> {:error, reason}
    end
  end

  def by_monitor(entries, monitor_ref) do
    Enum.find(entries, fn {_ref, entry} -> entry.monitor_ref == monitor_ref end)
  end

  def log_delivery(id, :ok),
    do: Logger.debug("MCP client delivered server-request response id=#{inspect(id)}")

  def log_delivery(id, {:error, reason}),
    do:
      Logger.error(
        "MCP client failed to deliver server-request response id=#{inspect(id)}: #{inspect(reason)}"
      )

  defp invoke(nil, method, _params), do: {:error, Error.method_not_found(method)}

  defp invoke(handler, method, params) when is_function(handler, 2),
    do: safely_invoke(fn -> handler.(method, params) end)

  defp invoke(handler, _method, params) when is_function(handler, 1),
    do: safely_invoke(fn -> handler.(params) end)

  defp safely_invoke(callback) do
    callback.()
  rescue
    exception ->
      Logger.error(
        "MCP client request handler failed " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, Error.internal_error("client request handler failed")}
  catch
    kind, reason ->
      Logger.error(
        "MCP client request handler failed " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      {:error, Error.internal_error("client request handler failed")}
  end
end
