defmodule MCP.Protocol.Types.ToolAnnotations do
  @moduledoc """
  Additional properties describing a tool's behavior.

  All properties are hints and not guaranteed. Clients SHOULD NOT
  rely on these for security decisions unless the server is trusted.
  """

  defstruct [:title, :read_only_hint, :destructive_hint, :idempotent_hint, :open_world_hint]

  @type t :: %__MODULE__{
          title: String.t() | nil,
          read_only_hint: boolean() | nil,
          destructive_hint: boolean() | nil,
          idempotent_hint: boolean() | nil,
          open_world_hint: boolean() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      title: Map.get(map, "title"),
      read_only_hint: Map.get(map, "readOnlyHint"),
      destructive_hint: Map.get(map, "destructiveHint"),
      idempotent_hint: Map.get(map, "idempotentHint"),
      open_world_hint: Map.get(map, "openWorldHint")
    }
  end

  defimpl Jason.Encoder, for: __MODULE__ do
    def encode(struct, opts) do
      struct
      |> Map.from_struct()
      |> Enum.reduce(%{}, fn
        {_key, nil}, acc -> acc
        {:read_only_hint, val}, acc -> Map.put(acc, :readOnlyHint, val)
        {:destructive_hint, val}, acc -> Map.put(acc, :destructiveHint, val)
        {:idempotent_hint, val}, acc -> Map.put(acc, :idempotentHint, val)
        {:open_world_hint, val}, acc -> Map.put(acc, :openWorldHint, val)
        {key, val}, acc -> Map.put(acc, key, val)
      end)
      |> Jason.Encode.map(opts)
    end
  end
end
