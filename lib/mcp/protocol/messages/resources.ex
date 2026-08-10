defmodule MCP.Protocol.Messages.Resources do
  @moduledoc """
  Message types for resource operations.
  """

  defmodule ListParams do
    @moduledoc """
    Parameters for `resources/list`.
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
    Result of `resources/list`.
    """

    alias MCP.Protocol.Types.Resource

    defstruct [:resources, :next_cursor, :meta]

    @type t :: %__MODULE__{
            resources: [Resource.t()],
            next_cursor: String.t() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        resources: map |> Map.fetch!("resources") |> Enum.map(&Resource.from_map/1),
        next_cursor: Map.get(map, "nextCursor"),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{resources: struct.resources}
        map = if struct.next_cursor, do: Map.put(map, :nextCursor, struct.next_cursor), else: map
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map
        Jason.Encode.map(map, opts)
      end
    end
  end

  defmodule ReadParams do
    @moduledoc """
    Parameters for `resources/read`.
    """

    @derive Jason.Encoder
    defstruct [:uri, :meta]

    @type t :: %__MODULE__{
            uri: String.t(),
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        uri: Map.fetch!(map, "uri"),
        meta: Map.get(map, "_meta")
      }
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = params) do
      map = %{"uri" => params.uri}
      if params.meta, do: Map.put(map, "_meta", params.meta), else: map
    end
  end

  defmodule ReadResult do
    @moduledoc """
    Result of `resources/read`.
    """

    alias MCP.Protocol.Types.ResourceContents

    defstruct [:contents, :meta]

    @type t :: %__MODULE__{
            contents: [ResourceContents.t()],
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        contents: map |> Map.fetch!("contents") |> Enum.map(&ResourceContents.from_map/1),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{contents: struct.contents}
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map
        Jason.Encode.map(map, opts)
      end
    end
  end

  defmodule SubscribeParams do
    @moduledoc """
    Parameters for `resources/subscribe`.
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

  defmodule UnsubscribeParams do
    @moduledoc """
    Parameters for `resources/unsubscribe`.
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

  defmodule ListTemplatesParams do
    @moduledoc """
    Parameters for `resources/templates/list`.
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

  defmodule ListTemplatesResult do
    @moduledoc """
    Result of `resources/templates/list`.
    """

    alias MCP.Protocol.Types.ResourceTemplate

    defstruct [:resource_templates, :next_cursor, :meta]

    @type t :: %__MODULE__{
            resource_templates: [ResourceTemplate.t()],
            next_cursor: String.t() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        resource_templates:
          map |> Map.fetch!("resourceTemplates") |> Enum.map(&ResourceTemplate.from_map/1),
        next_cursor: Map.get(map, "nextCursor"),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{resourceTemplates: struct.resource_templates}
        map = if struct.next_cursor, do: Map.put(map, :nextCursor, struct.next_cursor), else: map
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map
        Jason.Encode.map(map, opts)
      end
    end
  end
end
