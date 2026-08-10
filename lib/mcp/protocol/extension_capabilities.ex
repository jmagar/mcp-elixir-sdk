defmodule MCP.Protocol.ExtensionCapabilities do
  @moduledoc false

  @label ~r/^[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/
  @name ~r/^(?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9_.-]*[A-Za-z0-9])?$/

  @spec validate(term()) :: {:ok, map() | nil} | {:error, term()}
  def validate(nil), do: {:ok, nil}

  def validate(extensions) when is_map(extensions) do
    Enum.reduce_while(extensions, {:ok, %{}}, fn
      {key, settings}, {:ok, validated} when is_binary(key) and is_map(settings) ->
        cond do
          not valid_identifier?(key) ->
            {:halt, {:error, {:invalid_extension_identifier, key}}}

          not json_object?(settings) ->
            {:halt, {:error, {:invalid_extension_settings, key}}}

          true ->
            {:cont, {:ok, Map.put(validated, key, settings)}}
        end

      {key, _settings}, _acc when not is_binary(key) ->
        {:halt, {:error, {:invalid_extension_identifier, key}}}

      {key, _settings}, _acc ->
        {:halt, {:error, {:invalid_extension_settings, key}}}
    end)
  end

  def validate(_extensions), do: {:error, :extensions_must_be_an_object}

  @spec validate!(term()) :: map() | nil
  def validate!(extensions) do
    case validate(extensions) do
      {:ok, validated} -> validated
      {:error, reason} -> raise ArgumentError, "invalid extensions: #{inspect(reason)}"
    end
  end

  @spec valid_identifier?(term()) :: boolean()
  def valid_identifier?(identifier) when is_binary(identifier) do
    case String.split(identifier, "/", parts: 2) do
      [prefix, name] when prefix != "" ->
        Enum.all?(String.split(prefix, "."), &Regex.match?(@label, &1)) and
          Regex.match?(@name, name)

      _invalid ->
        false
    end
  end

  def valid_identifier?(_identifier), do: false

  @spec json_object?(term()) :: boolean()
  def json_object?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end)
  end

  def json_object?(_value), do: false

  @spec json_value?(term()) :: boolean()
  def json_value?(nil), do: true
  def json_value?(value) when is_boolean(value) or is_number(value) or is_binary(value), do: true
  def json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)
  def json_value?(value) when is_map(value), do: json_object?(value)
  def json_value?(_value), do: false
end
