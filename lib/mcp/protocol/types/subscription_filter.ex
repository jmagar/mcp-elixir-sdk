defmodule MCP.Protocol.Types.SubscriptionFilter do
  @moduledoc """
  Notification families selected by a `subscriptions/listen` request.

  Every field is opt-in. Boolean fields set to `false` and an empty resource
  subscription list are omitted when encoded.
  """

  @wire_keys [
    "toolsListChanged",
    "promptsListChanged",
    "resourcesListChanged",
    "resourceSubscriptions"
  ]

  defstruct tools_list_changed: false,
            prompts_list_changed: false,
            resources_list_changed: false,
            resource_subscriptions: []

  @type t :: %__MODULE__{
          tools_list_changed: boolean(),
          prompts_list_changed: boolean(),
          resources_list_changed: boolean(),
          resource_subscriptions: [String.t()]
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    validate_keys!(map)

    %__MODULE__{
      tools_list_changed: boolean_field!(map, "toolsListChanged"),
      prompts_list_changed: boolean_field!(map, "promptsListChanged"),
      resources_list_changed: boolean_field!(map, "resourcesListChanged"),
      resource_subscriptions: resource_subscriptions!(map)
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = filter) do
    validate_filter!(filter)

    %{}
    |> put_enabled("toolsListChanged", filter.tools_list_changed)
    |> put_enabled("promptsListChanged", filter.prompts_list_changed)
    |> put_enabled("resourcesListChanged", filter.resources_list_changed)
    |> put_resources(filter.resource_subscriptions)
  end

  defp validate_keys!(map) do
    case Map.keys(map) -- @wire_keys do
      [] -> :ok
      keys -> raise ArgumentError, "unknown subscription filter fields: #{inspect(keys)}"
    end
  end

  defp boolean_field!(map, key) do
    case Map.get(map, key, false) do
      value when is_boolean(value) -> value
      value -> raise ArgumentError, "#{key} must be a boolean, got: #{inspect(value)}"
    end
  end

  defp resource_subscriptions!(map) do
    case Map.get(map, "resourceSubscriptions", []) do
      values when is_list(values) ->
        if Enum.all?(values, &is_binary/1) do
          values
        else
          raise ArgumentError, "resourceSubscriptions must contain only strings"
        end

      value ->
        raise ArgumentError, "resourceSubscriptions must be a list, got: #{inspect(value)}"
    end
  end

  defp validate_filter!(filter) do
    Enum.each(
      [
        tools_list_changed: filter.tools_list_changed,
        prompts_list_changed: filter.prompts_list_changed,
        resources_list_changed: filter.resources_list_changed
      ],
      fn {field, value} ->
        unless is_boolean(value) do
          raise ArgumentError, "#{field} must be a boolean, got: #{inspect(value)}"
        end
      end
    )

    unless is_list(filter.resource_subscriptions) and
             Enum.all?(filter.resource_subscriptions, &is_binary/1) do
      raise ArgumentError, "resource_subscriptions must contain only strings"
    end
  end

  defp put_enabled(map, key, true), do: Map.put(map, key, true)
  defp put_enabled(map, _key, false), do: map

  defp put_resources(map, []), do: map
  defp put_resources(map, resources), do: Map.put(map, "resourceSubscriptions", resources)

  defimpl Jason.Encoder do
    alias MCP.Protocol.Types.SubscriptionFilter

    def encode(filter, opts) do
      filter
      |> SubscriptionFilter.to_map()
      |> Jason.Encode.map(opts)
    end
  end
end
