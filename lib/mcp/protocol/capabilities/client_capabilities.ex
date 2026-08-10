defmodule MCP.Protocol.Capabilities.ClientCapabilities do
  @moduledoc """
  Capabilities declared by an MCP client in every request's required metadata.
  """

  alias MCP.Protocol.Capabilities.{
    ElicitationCapabilities,
    RootCapabilities,
    SamplingCapabilities
  }

  alias MCP.Protocol.ExtensionCapabilities

  @known_keys ~w(roots sampling elicitation experimental extensions)

  defstruct [:roots, :sampling, :elicitation, :experimental, :extensions, extra: %{}]

  @type t :: %__MODULE__{
          roots: RootCapabilities.t() | nil,
          sampling: SamplingCapabilities.t() | nil,
          elicitation: ElicitationCapabilities.t() | nil,
          experimental: map() | nil,
          extensions: map() | nil,
          extra: map()
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    extensions = map |> Map.get("extensions") |> ExtensionCapabilities.validate!()

    %__MODULE__{
      roots: map |> Map.get("roots") |> parse_cap(RootCapabilities),
      sampling: map |> Map.get("sampling") |> parse_cap(SamplingCapabilities),
      elicitation: map |> Map.get("elicitation") |> parse_cap(ElicitationCapabilities),
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
    |> maybe_put("roots", capabilities.roots)
    |> maybe_put("sampling", capabilities.sampling)
    |> maybe_put("elicitation", capabilities.elicitation)
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
    alias MCP.Protocol.Capabilities.ClientCapabilities

    def encode(struct, opts) do
      struct
      |> ClientCapabilities.to_map()
      |> Jason.Encode.map(opts)
    end
  end
end
