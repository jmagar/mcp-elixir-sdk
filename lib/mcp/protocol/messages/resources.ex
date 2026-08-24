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

    alias MCP.Protocol.OpenObject
    alias MCP.Protocol.Types.Resource

    @known_keys ["resources", "nextCursor", "_meta"]

    defstruct [:resources, :next_cursor, :meta, extra: %{}]

    @type t :: %__MODULE__{
            resources: [Resource.t()],
            next_cursor: String.t() | nil,
            meta: map() | nil,
            extra: MCP.Protocol.extra_fields()
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        resources: map |> Map.fetch!("resources") |> Enum.map(&Resource.from_map/1),
        next_cursor: Map.get(map, "nextCursor"),
        meta: Map.get(map, "_meta"),
        extra: OpenObject.extra(map, @known_keys)
      }
    end

    def to_map(%__MODULE__{} = result) do
      %{"resources" => result.resources}
      |> maybe_put("nextCursor", result.next_cursor)
      |> maybe_put("_meta", result.meta)
      |> OpenObject.merge!(result.extra, @known_keys, "resources/list result")
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        Jason.Encode.map(@for.to_map(struct), opts)
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

    alias MCP.Protocol.OpenObject
    alias MCP.Protocol.Types.ResourceContents

    @known_keys ["contents", "_meta"]

    defstruct [:contents, :meta, extra: %{}]

    @type t :: %__MODULE__{
            contents: [ResourceContents.t()],
            meta: map() | nil,
            extra: MCP.Protocol.extra_fields()
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        contents: map |> Map.fetch!("contents") |> Enum.map(&ResourceContents.from_map/1),
        meta: Map.get(map, "_meta"),
        extra: OpenObject.extra(map, @known_keys)
      }
    end

    def to_map(%__MODULE__{} = result) do
      %{"contents" => result.contents}
      |> maybe_put("_meta", result.meta)
      |> OpenObject.merge!(result.extra, @known_keys, "resources/read result")
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        Jason.Encode.map(@for.to_map(struct), opts)
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

    alias MCP.Protocol.OpenObject
    alias MCP.Protocol.Types.ResourceTemplate

    @known_keys ["resourceTemplates", "nextCursor", "_meta"]

    defstruct [:resource_templates, :next_cursor, :meta, extra: %{}]

    @type t :: %__MODULE__{
            resource_templates: [ResourceTemplate.t()],
            next_cursor: String.t() | nil,
            meta: map() | nil,
            extra: MCP.Protocol.extra_fields()
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        resource_templates:
          map |> Map.fetch!("resourceTemplates") |> Enum.map(&ResourceTemplate.from_map/1),
        next_cursor: Map.get(map, "nextCursor"),
        meta: Map.get(map, "_meta"),
        extra: OpenObject.extra(map, @known_keys)
      }
    end

    def to_map(%__MODULE__{} = result) do
      %{"resourceTemplates" => result.resource_templates}
      |> maybe_put("nextCursor", result.next_cursor)
      |> maybe_put("_meta", result.meta)
      |> OpenObject.merge!(result.extra, @known_keys, "resources/templates/list result")
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
