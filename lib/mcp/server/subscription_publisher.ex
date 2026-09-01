defmodule MCP.Server.SubscriptionPublisher do
  @moduledoc """
  Publishes a server notification to matching live subscriptions.

  The registry and endpoint must match the values configured on the server
  transport. Publication validates metadata before fan-out and returns an
  error instead of terminating subscribers when the notification is malformed.
  Fan-out always attempts every matching subscriber; an overload or closed
  result is reported only after healthy siblings have received the event.
  """

  alias MCP.Protocol.Types.SubscriptionFilter
  alias MCP.Server.SubscriptionRegistry
  alias MCP.Server.SubscriptionWorker

  @spec publish(atom() | pid(), term(), String.t(), map() | nil) ::
          :ok
          | {:error, :invalid_registry | :invalid_notification_params | :queue_overflow | :closed}
  def publish(registry, endpoint, method, params) do
    with :ok <- validate_params(params),
         {:ok, prepared} <- SubscriptionWorker.prepare(method, params),
         {:ok, registry_name} <- SubscriptionRegistry.name(registry) do
      entries = Registry.lookup(registry_name, {:mcp_subscriptions, endpoint})
      dispatch(entries, method, params, prepared)
    end
  end

  defp validate_params(nil), do: :ok

  defp validate_params(params) when is_map(params) do
    case Map.fetch(params, "_meta") do
      {:ok, meta} when not is_map(meta) -> {:error, :invalid_notification_params}
      _meta -> :ok
    end
  end

  defp validate_params(_params), do: {:error, :invalid_notification_params}

  defp dispatch(entries, method, params, prepared) do
    Enum.reduce(entries, :ok, fn {worker, subscription}, result ->
      dispatch_entry(worker, subscription, method, params, prepared)
      |> merge_dispatch_result(result)
    end)
  end

  defp dispatch_entry(worker, subscription, method, params, prepared) do
    if matches?(subscription, method, params) do
      case SubscriptionWorker.publish_prepared(worker, subscription.admission, prepared) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp merge_dispatch_result(:ok, result), do: result
  defp merge_dispatch_result({:error, _reason} = error, :ok), do: error
  defp merge_dispatch_result({:error, _reason}, result), do: result

  defp matches?(%{honored: %SubscriptionFilter{} = filter}, method, _params)
       when method == "notifications/tools/list_changed",
       do: filter.tools_list_changed

  defp matches?(%{honored: %SubscriptionFilter{} = filter}, method, _params)
       when method == "notifications/prompts/list_changed",
       do: filter.prompts_list_changed

  defp matches?(%{honored: %SubscriptionFilter{} = filter}, method, _params)
       when method == "notifications/resources/list_changed",
       do: filter.resources_list_changed

  defp matches?(%{resource_subscription_set: uris}, method, %{"uri" => uri})
       when method == "notifications/resources/updated" do
    MapSet.member?(uris, uri)
  end

  defp matches?(%{honored: %SubscriptionFilter{}}, _method, _params), do: false
end
