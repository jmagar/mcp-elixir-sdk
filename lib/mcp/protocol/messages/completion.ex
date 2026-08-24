defmodule MCP.Protocol.Messages.Completion do
  @moduledoc """
  Message types for `completion/complete`.
  """

  defmodule Params do
    @moduledoc """
    Parameters for `completion/complete`.
    """

    defstruct [:ref, :argument, :context, :meta]

    @type t :: %__MODULE__{
            ref: map(),
            argument: map(),
            context: map() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        ref: Map.fetch!(map, "ref"),
        argument: Map.fetch!(map, "argument"),
        context: Map.get(map, "context"),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{ref: struct.ref, argument: struct.argument}
        map = if struct.context, do: Map.put(map, :context, struct.context), else: map
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map
        Jason.Encode.map(map, opts)
      end
    end
  end

  defmodule Result do
    @moduledoc """
    Result of `completion/complete`.
    """

    alias MCP.Protocol.OpenObject

    @known_keys ["completion", "_meta"]

    defstruct [:completion, :meta, extra: %{}]

    @type t :: %__MODULE__{
            completion: map(),
            meta: map() | nil,
            extra: map()
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        completion: Map.fetch!(map, "completion"),
        meta: Map.get(map, "_meta"),
        extra: OpenObject.extra(map, @known_keys)
      }
    end

    def to_map(%__MODULE__{} = result) do
      %{"completion" => result.completion}
      |> maybe_put("_meta", result.meta)
      |> OpenObject.merge!(result.extra, @known_keys, "completion result")
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
