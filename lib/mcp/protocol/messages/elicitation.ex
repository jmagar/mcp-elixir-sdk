defmodule MCP.Protocol.Messages.Elicitation do
  @moduledoc """
  Message types for `elicitation/create`.
  """

  defmodule Params do
    @moduledoc """
    Parameters for `elicitation/create`.

    **URL-mode elicitation is retained** in the 2026-07-28 stateless core (PO
    Ruling 5; published-final `2026-07-28` schema
    `5f5440bb26a62e2cf3440b92da5a667efa03b267` (tag `2026-07-28`),
    `schema/2026-07-28/schema.ts:2825/:2845` — `ElicitRequestURLParams.mode =
    "url"`, `url`, and client capability `elicitation.url` at `:769`). What
    2026-07-28
    removes is only the async **completion-correlation machinery**: the
    `elicitationId` field and the `notifications/elicitation/complete`
    notification (both 2025-11-25) — correlation moves to `requestState` under
    MRTR. The `elicitationId` field is therefore dropped here; `mode`/`url` stay.
    """

    defstruct [:mode, :message, :requested_schema, :url, :meta]

    @type t :: %__MODULE__{
            mode: String.t() | nil,
            message: String.t(),
            requested_schema: map() | nil,
            url: String.t() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        mode: Map.get(map, "mode"),
        message: Map.fetch!(map, "message"),
        requested_schema: Map.get(map, "requestedSchema"),
        url: Map.get(map, "url"),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{message: struct.message}

        map =
          struct
          |> Map.from_struct()
          |> Enum.reduce(map, fn
            {:message, _}, acc -> acc
            {_key, nil}, acc -> acc
            {:requested_schema, val}, acc -> Map.put(acc, :requestedSchema, val)
            {:meta, val}, acc -> Map.put(acc, :_meta, val)
            {key, val}, acc -> Map.put(acc, key, val)
          end)

        Jason.Encode.map(map, opts)
      end
    end
  end

  defmodule Result do
    @moduledoc """
    Result of `elicitation/create`.
    """

    defstruct [:action, :content, :meta]

    @type t :: %__MODULE__{
            action: String.t(),
            content: map() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        action: Map.fetch!(map, "action"),
        content: Map.get(map, "content"),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{action: struct.action}
        map = if struct.content, do: Map.put(map, :content, struct.content), else: map
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map
        Jason.Encode.map(map, opts)
      end
    end
  end
end
