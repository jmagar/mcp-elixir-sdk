defmodule MCP.Protocol.Types.Implementation do
  @moduledoc """
  Identifies an MCP client or server implementation.
  """

  alias MCP.Protocol.Types.Icon

  defstruct [:name, :version, :title, :description, :website_url, :icons]

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          website_url: String.t() | nil,
          icons: [Icon.t()] | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: Map.fetch!(map, "name"),
      version: Map.fetch!(map, "version"),
      title: Map.get(map, "title"),
      description: Map.get(map, "description"),
      website_url: Map.get(map, "websiteUrl"),
      icons: map |> Map.get("icons") |> parse_icons()
    }
  end

  defp parse_icons(nil), do: nil
  defp parse_icons(icons), do: Enum.map(icons, &Icon.from_map/1)

  defimpl Jason.Encoder, for: __MODULE__ do
    def encode(struct, opts) do
      struct
      |> Map.from_struct()
      |> Enum.reduce(%{}, fn
        {_key, nil}, acc -> acc
        {:website_url, val}, acc -> Map.put(acc, :websiteUrl, val)
        {key, val}, acc -> Map.put(acc, key, val)
      end)
      |> Jason.Encode.map(opts)
    end
  end
end
