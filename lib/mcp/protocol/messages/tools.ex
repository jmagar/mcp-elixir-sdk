defmodule MCP.Protocol.Messages.Tools do
  @moduledoc """
  Message types for `tools/list` and `tools/call`.
  """

  defmodule ListParams do
    @moduledoc """
    Parameters for `tools/list`.
    """

    @derive Jason.Encoder
    defstruct [:cursor, :meta]

    @type t :: %__MODULE__{
            cursor: String.t() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        cursor: Map.get(map, "cursor"),
        meta: Map.get(map, "_meta")
      }
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = params) do
      %{}
      |> maybe_put("cursor", params.cursor)
      |> maybe_put("_meta", params.meta)
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, val), do: Map.put(map, key, val)
  end

  defmodule ListResult do
    @moduledoc """
    Result of `tools/list`.
    """

    alias MCP.Protocol.Types.Tool

    defstruct [:tools, :next_cursor, :meta]

    @type t :: %__MODULE__{
            tools: [Tool.t()],
            next_cursor: String.t() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        tools: map |> Map.fetch!("tools") |> Enum.map(&Tool.from_map/1),
        next_cursor: Map.get(map, "nextCursor"),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{tools: struct.tools}

        map = if struct.next_cursor, do: Map.put(map, :nextCursor, struct.next_cursor), else: map
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map

        Jason.Encode.map(map, opts)
      end
    end
  end

  defmodule CallParams do
    @moduledoc """
    Parameters for `tools/call`.
    """

    @derive Jason.Encoder
    defstruct [:name, :arguments, :meta]

    @type t :: %__MODULE__{
            name: String.t(),
            arguments: map() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        name: Map.fetch!(map, "name"),
        arguments: Map.get(map, "arguments"),
        meta: Map.get(map, "_meta")
      }
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = params) do
      %{"name" => params.name}
      |> maybe_put("arguments", params.arguments)
      |> maybe_put("_meta", params.meta)
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, val), do: Map.put(map, key, val)
  end

  defmodule CallResult do
    @moduledoc """
    Result of `tools/call`.
    """

    alias MCP.Protocol.Types.Content

    @known_keys ["content", "structuredContent", "isError", "_meta"]

    defstruct [:content, structured_content: :absent, is_error: nil, meta: nil, extra: %{}]

    @type t :: %__MODULE__{
            content: [Content.content_block()],
            structured_content: MCP.Protocol.json_value() | :absent,
            is_error: boolean() | nil,
            meta: map() | nil,
            extra: %{optional(String.t()) => MCP.Protocol.json_value()}
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        content: map |> Map.fetch!("content") |> Enum.map(&Content.from_map/1),
        structured_content: Map.get(map, "structuredContent", :absent),
        is_error: Map.get(map, "isError"),
        meta: Map.get(map, "_meta"),
        extra: Map.drop(map, ["content", "structuredContent", "isError", "_meta"])
      }
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = result) do
      reject_extra_collisions!(result.extra)

      %{"content" => result.content}
      |> maybe_put("structuredContent", result.structured_content, :absent)
      |> maybe_put("isError", result.is_error, nil)
      |> maybe_put("_meta", result.meta, nil)
      |> Map.merge(result.extra)
    end

    defp reject_extra_collisions!(extra) when is_map(extra) do
      case Enum.find(Map.keys(extra), &(not is_binary(&1) or &1 in @known_keys)) do
        nil ->
          :ok

        key when is_binary(key) ->
          raise ArgumentError, "call result extra field collides with #{key}"

        key ->
          raise ArgumentError,
                "call result extra field names must be strings, got: #{inspect(key)}"
      end
    end

    defp reject_extra_collisions!(_extra),
      do: raise(ArgumentError, "call result extra fields must be a map")

    defp maybe_put(map, _key, value, value), do: map
    defp maybe_put(map, key, value, _absent), do: Map.put(map, key, value)

    defimpl Jason.Encoder, for: __MODULE__ do
      alias MCP.Protocol.Messages.Tools.CallResult

      def encode(struct, opts) do
        struct |> CallResult.to_map() |> Jason.Encode.map(opts)
      end
    end
  end
end
