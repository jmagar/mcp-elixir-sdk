defmodule MCP.Protocol.Types.Icon do
  @moduledoc """
  Icon for visual identification of tools, resources, prompts, etc.
  """

  defstruct [:src, :mime_type, :sizes, :theme]

  @type t :: %__MODULE__{
          src: String.t(),
          mime_type: String.t() | nil,
          sizes: [String.t()] | nil,
          theme: String.t() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      src: Map.fetch!(map, "src"),
      mime_type: Map.get(map, "mimeType"),
      sizes: Map.get(map, "sizes"),
      theme: Map.get(map, "theme")
    }
  end

  defimpl Jason.Encoder, for: __MODULE__ do
    def encode(struct, opts) do
      struct
      |> Map.from_struct()
      |> Enum.reduce(%{}, fn
        {_key, nil}, acc -> acc
        {:mime_type, val}, acc -> Map.put(acc, :mimeType, val)
        {key, val}, acc -> Map.put(acc, key, val)
      end)
      |> Jason.Encode.map(opts)
    end
  end
end
