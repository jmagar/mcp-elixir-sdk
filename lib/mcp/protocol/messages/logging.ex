defmodule MCP.Protocol.Messages.Logging do
  @moduledoc """
  Message types for logging operations.
  """

  defmodule SetLevelParams do
    @moduledoc """
    Parameters for `logging/setLevel`.
    """

    @derive Jason.Encoder
    defstruct [:level, :meta]

    @type t :: %__MODULE__{
            level: String.t(),
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        level: Map.fetch!(map, "level"),
        meta: Map.get(map, "_meta")
      }
    end
  end

  defmodule MessageParams do
    @moduledoc """
    Parameters for `notifications/message` (log message from server).
    """

    defstruct [:level, :logger, :data, :meta]

    @type t :: %__MODULE__{
            level: String.t(),
            logger: String.t() | nil,
            data: term(),
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        level: Map.fetch!(map, "level"),
        logger: Map.get(map, "logger"),
        data: Map.fetch!(map, "data"),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{level: struct.level, data: struct.data}
        map = if struct.logger, do: Map.put(map, :logger, struct.logger), else: map
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map
        Jason.Encode.map(map, opts)
      end
    end
  end
end
