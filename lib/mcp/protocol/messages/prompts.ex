defmodule MCP.Protocol.Messages.Prompts do
  @moduledoc """
  Message types for prompt operations.
  """

  defmodule ListParams do
    @moduledoc """
    Parameters for `prompts/list`.
    """

    @derive Jason.Encoder
    defstruct [:cursor, :meta]

    @type t :: %__MODULE__{cursor: String.t() | nil, meta: map() | nil}

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        cursor: Map.get(map, "cursor"),
        meta: Map.get(map, "_meta")
      }
    end
  end

  defmodule ListResult do
    @moduledoc """
    Result of `prompts/list`.
    """

    alias MCP.Protocol.OpenObject
    alias MCP.Protocol.Types.Prompt

    @known_keys ["prompts", "nextCursor", "_meta"]

    defstruct [:prompts, :next_cursor, :meta, extra: %{}]

    @type t :: %__MODULE__{
            prompts: [Prompt.t()],
            next_cursor: String.t() | nil,
            meta: map() | nil,
            extra: MCP.Protocol.extra_fields()
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        prompts: map |> Map.fetch!("prompts") |> Enum.map(&Prompt.from_map/1),
        next_cursor: Map.get(map, "nextCursor"),
        meta: Map.get(map, "_meta"),
        extra: OpenObject.extra(map, @known_keys)
      }
    end

    def to_map(%__MODULE__{} = result) do
      %{"prompts" => result.prompts}
      |> maybe_put("nextCursor", result.next_cursor)
      |> maybe_put("_meta", result.meta)
      |> OpenObject.merge!(result.extra, @known_keys, "prompts/list result")
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        Jason.Encode.map(@for.to_map(struct), opts)
      end
    end
  end

  defmodule GetParams do
    @moduledoc """
    Parameters for `prompts/get`.
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
      map = %{"name" => params.name}
      map = if params.arguments, do: Map.put(map, "arguments", params.arguments), else: map
      if params.meta, do: Map.put(map, "_meta", params.meta), else: map
    end
  end

  defmodule GetResult do
    @moduledoc """
    Result of `prompts/get`.
    """

    alias MCP.Protocol.OpenObject
    alias MCP.Protocol.Types.PromptMessage

    @known_keys ["description", "messages", "_meta"]

    defstruct [:description, :messages, :meta, extra: %{}]

    @type t :: %__MODULE__{
            description: String.t() | nil,
            messages: [PromptMessage.t()],
            meta: map() | nil,
            extra: MCP.Protocol.extra_fields()
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        description: Map.get(map, "description"),
        messages: map |> Map.fetch!("messages") |> Enum.map(&PromptMessage.from_map/1),
        meta: Map.get(map, "_meta"),
        extra: OpenObject.extra(map, @known_keys)
      }
    end

    def to_map(%__MODULE__{} = result) do
      %{"messages" => result.messages}
      |> maybe_put("description", result.description)
      |> maybe_put("_meta", result.meta)
      |> OpenObject.merge!(result.extra, @known_keys, "prompts/get result")
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
