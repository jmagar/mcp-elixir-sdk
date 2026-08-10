defmodule MCP.Protocol.Types.ModelPreferences do
  @moduledoc """
  Model selection preferences for sampling requests.
  """

  alias MCP.Protocol.Types.ModelHint

  defstruct [:hints, :cost_priority, :speed_priority, :intelligence_priority]

  @type t :: %__MODULE__{
          hints: [ModelHint.t()] | nil,
          cost_priority: float() | nil,
          speed_priority: float() | nil,
          intelligence_priority: float() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      hints: map |> Map.get("hints") |> parse_hints(),
      cost_priority: Map.get(map, "costPriority"),
      speed_priority: Map.get(map, "speedPriority"),
      intelligence_priority: Map.get(map, "intelligencePriority")
    }
  end

  defp parse_hints(nil), do: nil
  defp parse_hints(hints), do: Enum.map(hints, &ModelHint.from_map/1)

  defimpl Jason.Encoder, for: __MODULE__ do
    def encode(struct, opts) do
      struct
      |> Map.from_struct()
      |> Enum.reduce(%{}, fn
        {_key, nil}, acc -> acc
        {:cost_priority, val}, acc -> Map.put(acc, :costPriority, val)
        {:speed_priority, val}, acc -> Map.put(acc, :speedPriority, val)
        {:intelligence_priority, val}, acc -> Map.put(acc, :intelligencePriority, val)
        {key, val}, acc -> Map.put(acc, key, val)
      end)
      |> Jason.Encode.map(opts)
    end
  end
end
