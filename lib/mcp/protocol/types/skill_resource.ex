defmodule MCP.Protocol.Types.SkillResource do
  @moduledoc "A file declared by a static SEP-2640 skill manifest."

  @digest ~r/\Asha256:[0-9a-f]{64}\z/

  defstruct [:uri, :digest, :size]

  @type t :: %__MODULE__{uri: String.t(), digest: String.t(), size: non_neg_integer()}

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(%{"uri" => uri, "digest" => digest, "size" => size} = map)
      when map_size(map) == 3 and is_binary(uri) and is_binary(digest) and
             is_integer(size) and size >= 0 do
    if Regex.match?(@digest, digest) do
      {:ok, %__MODULE__{uri: uri, digest: digest, size: size}}
    else
      {:error, :invalid_digest}
    end
  end

  def decode(_value), do: {:error, :invalid_skill_resource}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = resource) do
    %{"uri" => resource.uri, "digest" => resource.digest, "size" => resource.size}
  end

  defimpl Jason.Encoder do
    def encode(resource, opts), do: Jason.Encode.map(@for.to_map(resource), opts)
  end
end
