defmodule MCP.Protocol.JSONBudget do
  @moduledoc false

  @max_depth 64

  @spec check(term(), pos_integer()) :: :ok | {:error, :too_large | :too_deep}
  def check(value, limit) when is_integer(limit) and limit > 0 do
    case consume(value, limit, 0) do
      {:ok, _remaining} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp consume(_value, _remaining, depth) when depth > @max_depth, do: {:error, :too_deep}
  defp consume(_value, remaining, _depth) when remaining < 0, do: {:error, :too_large}

  defp consume(value, remaining, _depth) when is_binary(value),
    do: debit(remaining, byte_size(value) + 2)

  defp consume(value, remaining, _depth)
       when is_number(value) or is_boolean(value) or is_nil(value),
       do: debit(remaining, 16)

  defp consume(values, remaining, depth) when is_list(values) do
    Enum.reduce_while(values, debit(remaining, 2), fn value, result ->
      continue_consume(result, value, depth + 1)
    end)
  end

  defp consume(value, remaining, depth) when is_map(value) do
    Enum.reduce_while(value, debit(remaining, 2), fn {key, item}, result ->
      with {:ok, remaining} <- result,
           {:ok, remaining} <- consume(to_string(key), remaining, depth + 1),
           {:ok, remaining} <- consume(item, remaining, depth + 1) do
        {:cont, {:ok, remaining}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp consume(_value, _remaining, _depth), do: {:error, :too_large}

  defp continue_consume({:ok, remaining}, value, depth) do
    case consume(value, remaining, depth) do
      {:ok, remaining} -> {:cont, {:ok, remaining}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp continue_consume({:error, reason}, _value, _depth), do: {:halt, {:error, reason}}

  defp debit(remaining, amount) when remaining >= amount, do: {:ok, remaining - amount}
  defp debit(_remaining, _amount), do: {:error, :too_large}
end
