defmodule MCP.Protocol.OpenObject do
  @moduledoc false

  alias MCP.Protocol.ExtensionCapabilities

  @spec extra(map(), [String.t()]) :: map()
  def extra(map, known_keys), do: Map.drop(map, known_keys)

  @spec merge!(map(), map(), [String.t()], String.t()) :: map()
  def merge!(known, extra, known_keys, label) when is_map(extra) do
    case Enum.find(extra, fn {key, value} ->
           not is_binary(key) or key in known_keys or
             not ExtensionCapabilities.json_value?(value)
         end) do
      nil ->
        Map.merge(known, extra)

      {key, _value} when not is_binary(key) ->
        raise ArgumentError, "#{label} extra field names must be strings, got: #{inspect(key)}"

      {key, _value} ->
        if key in known_keys do
          raise ArgumentError, "#{label} extra field collides with #{key}"
        else
          raise ArgumentError, "#{label} extra field #{key} must contain a JSON value"
        end
    end
  end

  def merge!(_known, _extra, _known_keys, label),
    do: raise(ArgumentError, "#{label} extra fields must be a map")
end
