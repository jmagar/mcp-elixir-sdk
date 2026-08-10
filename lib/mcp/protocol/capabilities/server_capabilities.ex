defmodule MCP.Protocol.Capabilities.ServerCapabilities do
  @moduledoc """
  Capabilities advertised by an MCP server through `server/discover`.
  """

  alias MCP.Protocol.Capabilities.{
    CompletionCapabilities,
    LoggingCapabilities,
    PromptCapabilities,
    ResourceCapabilities,
    ToolCapabilities
  }

  alias MCP.Protocol.ExtensionCapabilities

  @known_keys ~w(tools resources prompts logging completions experimental extensions)

  defstruct [
    :tools,
    :resources,
    :prompts,
    :logging,
    :completions,
    :experimental,
    :extensions,
    extra: %{}
  ]

  @type t :: %__MODULE__{
          tools: ToolCapabilities.t() | nil,
          resources: ResourceCapabilities.t() | nil,
          prompts: PromptCapabilities.t() | nil,
          logging: LoggingCapabilities.t() | nil,
          completions: CompletionCapabilities.t() | nil,
          experimental: map() | nil,
          extensions: map() | nil,
          extra: map()
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    extensions = map |> Map.get("extensions") |> ExtensionCapabilities.validate!()

    %__MODULE__{
      tools: map |> Map.get("tools") |> parse_cap(ToolCapabilities),
      resources: map |> Map.get("resources") |> parse_cap(ResourceCapabilities),
      prompts: map |> Map.get("prompts") |> parse_cap(PromptCapabilities),
      logging: map |> Map.get("logging") |> parse_cap(LoggingCapabilities),
      completions: map |> Map.get("completions") |> parse_cap(CompletionCapabilities),
      experimental: Map.get(map, "experimental"),
      extensions: extensions,
      extra: Map.drop(map, @known_keys)
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = capabilities) do
    extensions = ExtensionCapabilities.validate!(capabilities.extensions)
    extra = validate_extra!(capabilities.extra)

    if Enum.any?(@known_keys, &Map.has_key?(extra, &1)) do
      raise ArgumentError, "capability extra fields collide with known fields"
    end

    extra
    |> maybe_put("tools", capabilities.tools)
    |> maybe_put("resources", capabilities.resources)
    |> maybe_put("prompts", capabilities.prompts)
    |> maybe_put("logging", capabilities.logging)
    |> maybe_put("completions", capabilities.completions)
    |> maybe_put("experimental", capabilities.experimental)
    |> maybe_put("extensions", extensions)
  end

  defp parse_cap(nil, _module), do: nil
  defp parse_cap(map, module), do: module.from_map(map)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp validate_extra!(extra) when is_map(extra) do
    if Enum.all?(extra, fn {key, value} ->
         is_binary(key) and ExtensionCapabilities.json_value?(value)
       end) do
      extra
    else
      raise ArgumentError, "capability extra fields must be string-keyed JSON values"
    end
  end

  defp validate_extra!(_extra),
    do: raise(ArgumentError, "capability extra fields must be a map")

  defimpl Jason.Encoder, for: __MODULE__ do
    alias MCP.Protocol.Capabilities.ServerCapabilities

    def encode(struct, opts) do
      struct
      |> ServerCapabilities.to_map()
      |> Jason.Encode.map(opts)
    end
  end
end
