defmodule MCP.Protocol.Types.Tool do
  @moduledoc """
  An MCP tool definition.

  Tools are functions that can be called by an LLM via the MCP client.
  """

  alias MCP.Protocol.Types.{Icon, ToolAnnotations}

  @known_keys [
    "name",
    "title",
    "description",
    "inputSchema",
    "outputSchema",
    "annotations",
    "icons",
    "_meta"
  ]

  defstruct [
    :name,
    :title,
    :description,
    :input_schema,
    :output_schema,
    :annotations,
    :icons,
    :meta,
    extra: %{}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          input_schema: map(),
          output_schema: map() | nil,
          annotations: ToolAnnotations.t() | nil,
          icons: [Icon.t()] | nil,
          meta: map() | nil,
          extra: %{optional(String.t()) => MCP.Protocol.json_value()}
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: Map.fetch!(map, "name"),
      title: Map.get(map, "title"),
      description: Map.get(map, "description"),
      input_schema: map |> Map.fetch!("inputSchema") |> validate_input_schema!(),
      output_schema: map |> Map.get("outputSchema") |> validate_output_schema!(),
      annotations: map |> Map.get("annotations") |> parse_annotations(),
      icons: map |> Map.get("icons") |> parse_icons(),
      meta: Map.get(map, "_meta"),
      extra: Map.drop(map, @known_keys)
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = tool) do
    validate_input_schema!(tool.input_schema)
    validate_output_schema!(tool.output_schema)
    reject_extra_collisions!(tool.extra)

    %{"name" => tool.name, "inputSchema" => tool.input_schema}
    |> maybe_put("title", tool.title)
    |> maybe_put("description", tool.description)
    |> maybe_put("outputSchema", tool.output_schema)
    |> maybe_put("annotations", tool.annotations)
    |> maybe_put("icons", tool.icons)
    |> maybe_put("_meta", tool.meta)
    |> Map.merge(tool.extra)
  end

  defp validate_input_schema!(%{"type" => "object"} = schema), do: schema

  defp validate_input_schema!(_schema) do
    raise ArgumentError, "inputSchema root must have type object"
  end

  defp validate_output_schema!(nil), do: nil
  defp validate_output_schema!(schema) when is_map(schema), do: schema

  defp validate_output_schema!(_schema) do
    raise ArgumentError, "outputSchema must be a JSON object"
  end

  defp reject_extra_collisions!(extra) when is_map(extra) do
    case Enum.find(Map.keys(extra), &(not is_binary(&1) or &1 in @known_keys)) do
      nil ->
        :ok

      key when is_binary(key) ->
        raise ArgumentError, "tool extra field collides with #{key}"

      key ->
        raise ArgumentError, "tool extra field names must be strings, got: #{inspect(key)}"
    end
  end

  defp reject_extra_collisions!(_extra),
    do: raise(ArgumentError, "tool extra fields must be a map")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_annotations(nil), do: nil
  defp parse_annotations(map), do: ToolAnnotations.from_map(map)

  defp parse_icons(nil), do: nil
  defp parse_icons(icons), do: Enum.map(icons, &Icon.from_map/1)

  defimpl Jason.Encoder, for: __MODULE__ do
    alias MCP.Protocol.Types.Tool

    def encode(struct, opts) do
      struct |> Tool.to_map() |> Jason.Encode.map(opts)
    end
  end
end
