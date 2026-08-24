defmodule MCP.Protocol.Messages.Roots do
  @moduledoc """
  Message types for `roots/list`.
  """

  defmodule ListParams do
    @moduledoc """
    Parameters for `roots/list` (empty).
    """

    @derive Jason.Encoder
    defstruct [:meta]

    @type t :: %__MODULE__{meta: map() | nil}

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{meta: Map.get(map, "_meta")}
    end
  end

  defmodule ListResult do
    @moduledoc """
    Result of `roots/list`.
    """

    alias MCP.Protocol.OpenObject
    alias MCP.Protocol.Types.Root

    @known_keys ["roots", "_meta"]

    defstruct [:roots, :meta, extra: %{}]

    @type t :: %__MODULE__{
            roots: [Root.t()],
            meta: map() | nil,
            extra: %{optional(String.t()) => MCP.Protocol.json_value()}
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        roots: map |> Map.fetch!("roots") |> Enum.map(&Root.from_map/1),
        meta: Map.get(map, "_meta"),
        extra: OpenObject.extra(map, @known_keys)
      }
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = result) do
      %{"roots" => result.roots}
      |> maybe_put("_meta", result.meta)
      |> OpenObject.merge!(result.extra, @known_keys, "roots/list result")
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        Jason.Encode.map(@for.to_map(struct), opts)
      end
    end
  end
end
