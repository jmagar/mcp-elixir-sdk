defmodule MCP.Protocol.LegacyAdapter do
  @moduledoc """
  Contract for a stateful MCP protocol revision.

  Legacy revisions share an initialized lifecycle, but keep their version
  validation and wire projections behind separate adapters.
  """

  @type initialize_result :: map()

  @callback version() :: String.t()
  @callback initialize_params(map() | struct(), map() | struct()) :: map()
  @callback validate_initialize_result(initialize_result()) ::
              :ok | {:error, {:unexpected_protocol_version, term()}}
  @callback project_capabilities(map() | struct()) :: map() | struct()
end
