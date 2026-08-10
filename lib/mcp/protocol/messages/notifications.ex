defmodule MCP.Protocol.Messages.Notifications do
  @moduledoc """
  Parameter types for various MCP notifications.
  """

  defmodule ProgressParams do
    @moduledoc """
    Parameters for `notifications/progress`.
    """

    defstruct [:progress_token, :progress, :total, :message, :meta]

    @type t :: %__MODULE__{
            progress_token: integer() | String.t(),
            progress: number(),
            total: number() | nil,
            message: String.t() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        progress_token: Map.fetch!(map, "progressToken"),
        progress: Map.fetch!(map, "progress"),
        total: Map.get(map, "total"),
        message: Map.get(map, "message"),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{progressToken: struct.progress_token, progress: struct.progress}
        map = if struct.total, do: Map.put(map, :total, struct.total), else: map
        map = if struct.message, do: Map.put(map, :message, struct.message), else: map
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map
        Jason.Encode.map(map, opts)
      end
    end
  end

  defmodule CancelledParams do
    @moduledoc """
    Parameters for `notifications/cancelled`.
    """

    defstruct [:request_id, :reason, :meta]

    @type t :: %__MODULE__{
            request_id: integer() | String.t() | nil,
            reason: String.t() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        request_id: Map.get(map, "requestId"),
        reason: Map.get(map, "reason"),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{}
        map = if struct.request_id, do: Map.put(map, :requestId, struct.request_id), else: map
        map = if struct.reason, do: Map.put(map, :reason, struct.reason), else: map
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map
        Jason.Encode.map(map, opts)
      end
    end
  end

  defmodule ResourceUpdatedParams do
    @moduledoc """
    Parameters for `notifications/resources/updated`.
    """

    @derive Jason.Encoder
    defstruct [:uri, :meta]

    @type t :: %__MODULE__{uri: String.t(), meta: map() | nil}

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        uri: Map.fetch!(map, "uri"),
        meta: Map.get(map, "_meta")
      }
    end
  end
end
