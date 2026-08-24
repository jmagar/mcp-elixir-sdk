defmodule MCP.Protocol.Messages.Skills.GetResult do
  @moduledoc "Result of `skills/get`."

  alias MCP.Protocol.Types.Skill

  defstruct [:skill, :meta, result_type: "complete"]

  @type t :: %__MODULE__{skill: Skill.t(), result_type: String.t(), meta: map() | nil}

  @spec decode(term(), keyword()) :: {:ok, t()} | {:error, term()}
  def decode(map, opts \\ [])

  def decode(%{"skill" => skill} = map, opts) do
    with "complete" <- Map.get(map, "resultType", "complete"),
         meta when is_nil(meta) or is_map(meta) <- Map.get(map, "_meta"),
         {:ok, decoded} <- Skill.decode_and_validate(skill, opts) do
      {:ok, %__MODULE__{skill: decoded, result_type: "complete", meta: meta}}
    else
      _ -> {:error, :invalid_skills_get_result}
    end
  end

  def decode(_map, _opts), do: {:error, :invalid_skills_get_result}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{"resultType" => result.result_type, "skill" => Skill.to_map(result.skill)}
    |> maybe_put("_meta", result.meta)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defimpl Jason.Encoder do
    def encode(result, opts), do: Jason.Encode.map(@for.to_map(result), opts)
  end
end
