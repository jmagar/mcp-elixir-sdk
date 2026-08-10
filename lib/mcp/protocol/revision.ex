defmodule MCP.Protocol.Revision do
  @moduledoc """
  Registry for MCP protocol revisions supported by the SDK.

  Revision identifiers remain binaries at every external boundary. Legacy
  adapters are selected from this fixed registry without atom conversion.
  """

  alias MCP.Protocol.Legacy.{V2025_06_18, V2025_11_25}

  @modern "2026-07-28"
  @supported [@modern, "2025-11-25", "2025-06-18"]
  @adapters %{
    "2025-11-25" => V2025_11_25,
    "2025-06-18" => V2025_06_18
  }

  @spec preferred() :: String.t()
  def preferred, do: @modern

  @spec supported() :: [String.t(), ...]
  def supported, do: @supported

  @spec fetch(String.t()) ::
          {:ok, :stateless | module()} | {:error, {:unsupported_protocol_version, term()}}
  def fetch(@modern), do: {:ok, :stateless}

  def fetch(version) when is_binary(version) do
    case Map.fetch(@adapters, version) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unsupported_protocol_version, version}}
    end
  end

  def fetch(version), do: {:error, {:unsupported_protocol_version, version}}

  @spec legacy?(String.t()) :: boolean()
  def legacy?(version), do: Map.has_key?(@adapters, version)
end
