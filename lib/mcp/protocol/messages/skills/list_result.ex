defmodule MCP.Protocol.Messages.Skills.ListResult do
  @moduledoc "Result of `skills/list`."

  alias MCP.Protocol.Types.Skill

  defstruct [:skills, :next_cursor, :ttl_ms, :cache_scope, :meta, result_type: "complete"]

  @type t :: %__MODULE__{
          skills: [Skill.t()],
          next_cursor: String.t() | nil,
          result_type: String.t(),
          ttl_ms: non_neg_integer() | nil,
          cache_scope: String.t() | nil,
          meta: map() | nil
        }

  @spec decode(term(), keyword()) :: {:ok, t()} | {:error, term()}
  def decode(map, opts \\ [])

  def decode(%{"skills" => skills} = map, opts) when is_list(skills) do
    with :ok <- validate_envelope(map),
         {:ok, decoded} <- decode_skills(skills, opts) do
      {:ok,
       %__MODULE__{
         skills: decoded,
         next_cursor: Map.get(map, "nextCursor"),
         result_type: Map.get(map, "resultType", "complete"),
         ttl_ms: Map.get(map, "ttlMs"),
         cache_scope: Map.get(map, "cacheScope"),
         meta: Map.get(map, "_meta")
       }}
    end
  end

  def decode(_map, _opts), do: {:error, :invalid_skills_list_result}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{"resultType" => result.result_type, "skills" => Enum.map(result.skills, &Skill.to_map/1)}
    |> maybe_put("nextCursor", result.next_cursor)
    |> maybe_put("ttlMs", result.ttl_ms)
    |> maybe_put("cacheScope", result.cache_scope)
    |> maybe_put("_meta", result.meta)
  end

  defp decode_skills(skills, opts) do
    Enum.reduce_while(skills, {:ok, [], MapSet.new()}, fn value, {:ok, acc, seen} ->
      with {:ok, skill} <- Skill.decode_and_validate(value, opts),
           false <- MapSet.member?(seen, skill.uri) do
        {:cont, {:ok, [skill | acc], MapSet.put(seen, skill.uri)}}
      else
        true -> {:halt, {:error, :duplicate_skill_uri}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded, _seen} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp validate_envelope(map) do
    if valid_optional?(Map.get(map, "nextCursor"), &is_binary/1) and
         Map.get(map, "resultType", "complete") == "complete" and
         valid_optional?(Map.get(map, "ttlMs"), &(is_integer(&1) and &1 >= 0)) and
         valid_optional?(Map.get(map, "cacheScope"), &(&1 in ["public", "private"])) and
         valid_optional?(Map.get(map, "_meta"), &is_map/1) do
      :ok
    else
      {:error, :invalid_skills_list_result}
    end
  end

  defp valid_optional?(nil, _validator), do: true
  defp valid_optional?(value, validator), do: validator.(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defimpl Jason.Encoder do
    def encode(result, opts), do: Jason.Encode.map(@for.to_map(result), opts)
  end
end
