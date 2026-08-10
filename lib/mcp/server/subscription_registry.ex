defmodule MCP.Server.SubscriptionRegistry do
  @moduledoc false

  @spec name(atom() | pid()) :: {:ok, atom()} | {:error, :invalid_registry}
  def name(registry) when is_atom(registry), do: validate(registry)

  def name(registry) when is_pid(registry) do
    case Process.info(registry, :registered_name) do
      {:registered_name, name} when is_atom(name) -> validate(name)
      _ -> {:error, :invalid_registry}
    end
  end

  def name(_registry), do: {:error, :invalid_registry}

  defp validate(registry) do
    Registry.lookup(registry, {__MODULE__, :probe})
    {:ok, registry}
  rescue
    ArgumentError -> {:error, :invalid_registry}
  catch
    :exit, _reason -> {:error, :invalid_registry}
  end
end
