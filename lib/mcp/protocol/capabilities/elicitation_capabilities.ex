defmodule MCP.Protocol.Capabilities.ElicitationCapabilities do
  @moduledoc """
  Client capability for elicitation (form and/or URL modes).
  """

  defstruct [:form, :url]

  @type t :: %__MODULE__{
          form: map() | nil,
          url: map() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      form: Map.get(map, "form"),
      url: Map.get(map, "url")
    }
  end

  defimpl Jason.Encoder, for: __MODULE__ do
    def encode(struct, opts) do
      struct
      |> Map.from_struct()
      |> Enum.reduce(%{}, fn
        {_key, nil}, acc -> acc
        {key, val}, acc -> Map.put(acc, key, val)
      end)
      |> Jason.Encode.map(opts)
    end
  end
end
