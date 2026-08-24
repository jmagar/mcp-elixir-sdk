defmodule MCP.Apps.ResolvedApp do
  @moduledoc "A validated UI resource bound to the exact MCP client that resolved it."

  defstruct [:client, :tool, :resource_uri, :content, :ui, :raw_result]

  @type t :: %__MODULE__{
          client: pid(),
          tool: map(),
          resource_uri: String.t(),
          content: {:text | :blob, String.t()},
          ui: map(),
          raw_result: map()
        }
end
