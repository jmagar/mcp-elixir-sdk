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

    alias MCP.Protocol.Types.Root

    defstruct [:roots, :meta]

    @type t :: %__MODULE__{
            roots: [Root.t()],
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        roots: map |> Map.fetch!("roots") |> Enum.map(&Root.from_map/1),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{roots: struct.roots}
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map
        Jason.Encode.map(map, opts)
      end
    end
  end
end
