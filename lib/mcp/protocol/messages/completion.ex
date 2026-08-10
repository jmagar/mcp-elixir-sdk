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

    defstruct [:completion, :meta]

    @type t :: %__MODULE__{
            completion: map(),
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        completion: Map.fetch!(map, "completion"),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{completion: struct.completion}
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map
        Jason.Encode.map(map, opts)
      end
    end
  end
end
