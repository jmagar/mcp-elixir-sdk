# Version modules mirror the protocol's date identifier deliberately.
# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule MCP.Protocol.Legacy.V2025_11_25 do
  @moduledoc "MCP 2025-11-25 initialized-lifecycle adapter."

  @behaviour MCP.Protocol.LegacyAdapter

  @version "2025-11-25"

  @impl true
  def version, do: @version

  @impl true
  def initialize_params(client_info, capabilities) do
    %{
      "protocolVersion" => @version,
      "clientInfo" => wire_map(client_info),
      "capabilities" => wire_map(capabilities)
    }
  end

  @impl true
  def validate_initialize_result(%{"protocolVersion" => @version}), do: :ok

  def validate_initialize_result(%{"protocolVersion" => version}),
    do: {:error, {:unexpected_protocol_version, version}}

  def validate_initialize_result(result),
    do: {:error, {:unexpected_protocol_version, Map.get(result, "protocolVersion")}}

  @impl true
  def project_capabilities(capabilities), do: capabilities

  defp wire_map(value), do: value |> Jason.encode!() |> Jason.decode!()
end
