defmodule MCP.Apps.Limits do
  @moduledoc "Configurable resource and bridge validation budgets."

  @default_bytes 1_000_000
  defstruct max_resource_bytes: @default_bytes,
            max_message_bytes: @default_bytes,
            max_uri_bytes: 2_048,
            max_depth: 32,
            max_nodes: 10_000,
            max_csp_entries: 64,
            max_csp_entry_bytes: 2_048,
            max_correlations: 256

  @type t :: %__MODULE__{}

  @spec new(keyword() | t()) :: t()
  def new(%__MODULE__{} = limits), do: validate!(limits)
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts) |> validate!()

  defp validate!(limits) do
    limits
    |> Map.from_struct()
    |> Enum.each(fn
      {_key, value} when is_integer(value) and value > 0 ->
        :ok

      {key, value} ->
        raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
    end)

    limits
  end
end
