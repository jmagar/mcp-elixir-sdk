defmodule MCP.Protocol.Messages.Subscriptions.ListenResult do
  @moduledoc """
  Final result sent when a `subscriptions/listen` stream closes gracefully.
  """

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  defstruct [:meta, result_type: "complete"]

  @type t :: %__MODULE__{
          meta: map(),
          result_type: String.t()
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      meta: map |> Map.fetch!("_meta") |> validate_meta!(),
      result_type: map |> Map.fetch!("resultType") |> validate_result_type!()
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{
      "_meta" => validate_meta!(result.meta),
      "resultType" => validate_result_type!(result.result_type)
    }
  end

  defp validate_meta!(meta) when is_map(meta) do
    case Map.get(meta, @subscription_id_key) do
      id when is_binary(id) or is_integer(id) -> meta
      _ -> raise ArgumentError, "_meta must contain a string or integer subscription ID"
    end
  end

  defp validate_meta!(_meta) do
    raise ArgumentError, "_meta must contain a string or integer subscription ID"
  end

  defp validate_result_type!("complete"), do: "complete"

  defp validate_result_type!(result_type) do
    raise ArgumentError, "resultType must be complete, got: #{inspect(result_type)}"
  end

  defimpl Jason.Encoder do
    alias MCP.Protocol.Messages.Subscriptions.ListenResult

    def encode(result, opts) do
      result
      |> ListenResult.to_map()
      |> Jason.Encode.map(opts)
    end
  end
end
