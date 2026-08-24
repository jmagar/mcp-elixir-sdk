defmodule MCP.Protocol.Messages.Skills.GetParams do
  @moduledoc "Parameters for `skills/get`."

  defstruct [:uri, :meta]

  @type t :: %__MODULE__{uri: String.t(), meta: map() | nil}

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(%{"uri" => uri} = map) when is_binary(uri) do
    meta = Map.get(map, "_meta")

    if Enum.all?(Map.keys(map), &(&1 in ["uri", "_meta"])) and
         (not Map.has_key?(map, "_meta") or is_map(meta)),
       do: {:ok, %__MODULE__{uri: uri, meta: meta}},
       else: {:error, :invalid_skills_get_params}
  end

  def decode(_map), do: {:error, :invalid_skills_get_params}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = params) do
    if params.meta,
      do: %{"uri" => params.uri, "_meta" => params.meta},
      else: %{"uri" => params.uri}
  end

  defimpl Jason.Encoder do
    def encode(params, opts), do: Jason.Encode.map(@for.to_map(params), opts)
  end
end
