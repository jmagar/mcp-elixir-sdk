defmodule MCP.Server.SubscriptionPublisher do
  @moduledoc """
  Publishes a server notification to matching live subscriptions.

  The registry and endpoint must match the values configured on the server
  transport. Publication validates metadata before fan-out and returns an
  error instead of terminating subscribers when the notification is malformed.
  """

  alias MCP.Protocol.Types.SubscriptionFilter
  alias MCP.Server.SubscriptionRegistry
  alias MCP.Server.SubscriptionWorker

  @spec publish(atom() | pid(), term(), String.t(), map() | nil) ::
          :ok | {:error, :invalid_registry | :invalid_notification_params}
  def publish(registry, endpoint, method, params) do
    with :ok <- validate_params(params),
         {:ok, registry_name} <- SubscriptionRegistry.name(registry) do
      entries = Registry.lookup(registry_name, {:mcp_subscriptions, endpoint})
      dispatch(entries, method, params)

      :ok
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

  defp dispatch(entries, method, params) do
    Enum.each(entries, fn {worker, %{honored: honored}} ->
      if matches?(honored, method, params) do
        SubscriptionWorker.publish(worker, method, params)
      end
    end)
  end

  defp matches?(%SubscriptionFilter{} = filter, method, _params)
       when method == "notifications/tools/list_changed",
       do: filter.tools_list_changed

  defp matches?(%SubscriptionFilter{} = filter, method, _params)
       when method == "notifications/prompts/list_changed",
       do: filter.prompts_list_changed

  defp matches?(%SubscriptionFilter{} = filter, method, _params)
       when method == "notifications/resources/list_changed",
       do: filter.resources_list_changed

  defp matches?(%SubscriptionFilter{} = filter, method, %{"uri" => uri})
       when method == "notifications/resources/updated" do
    uri in filter.resource_subscriptions
  end

  defp matches?(%SubscriptionFilter{}, _method, _params), do: false
end
