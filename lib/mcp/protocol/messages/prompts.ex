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

    alias MCP.Protocol.Types.Prompt

    defstruct [:prompts, :next_cursor, :meta]

    @type t :: %__MODULE__{
            prompts: [Prompt.t()],
            next_cursor: String.t() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        prompts: map |> Map.fetch!("prompts") |> Enum.map(&Prompt.from_map/1),
        next_cursor: Map.get(map, "nextCursor"),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{prompts: struct.prompts}
        map = if struct.next_cursor, do: Map.put(map, :nextCursor, struct.next_cursor), else: map
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map
        Jason.Encode.map(map, opts)
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

    alias MCP.Protocol.Types.PromptMessage

    defstruct [:description, :messages, :meta]

    @type t :: %__MODULE__{
            description: String.t() | nil,
            messages: [PromptMessage.t()],
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        description: Map.get(map, "description"),
        messages: map |> Map.fetch!("messages") |> Enum.map(&PromptMessage.from_map/1),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{messages: struct.messages}
        map = if struct.description, do: Map.put(map, :description, struct.description), else: map
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map
        Jason.Encode.map(map, opts)
      end
    end
  end
end
