defmodule MCP.Transport.StreamableHTTP.SecurityPolicy do
  @moduledoc """
  Validated security and resource policy for Streamable HTTP clients.

  Defaults reject redirects, retries, unbounded responses, and plaintext HTTP
  outside loopback destinations.
  """

  defstruct redirect: :reject,
            retry: false,
            connect_timeout: 5_000,
            receive_timeout: 30_000,
            request_timeout: 60_000,
            max_response_bytes: 1_000_000,
            max_decoded_response_bytes: 1_000_000,
            max_sse_event_bytes: 1_000_000,
            compression: :disabled,
            allow_non_loopback_http: false

  @type t :: %__MODULE__{
          redirect: :reject,
          retry: false,
          connect_timeout: pos_integer(),
          receive_timeout: pos_integer(),
          request_timeout: pos_integer(),
          max_response_bytes: pos_integer(),
          max_decoded_response_bytes: pos_integer(),
          max_sse_event_bytes: pos_integer(),
          compression: :disabled,
          allow_non_loopback_http: boolean()
        }

  @keys [
    :redirect,
    :retry,
    :connect_timeout,
    :receive_timeout,
    :request_timeout,
    :max_response_bytes,
    :max_decoded_response_bytes,
    :max_sse_event_bytes,
    :compression,
    :allow_non_loopback_http
  ]
  @positive_keys [
    :connect_timeout,
    :receive_timeout,
    :request_timeout,
    :max_response_bytes,
    :max_decoded_response_bytes,
    :max_sse_event_bytes
  ]

  @spec default() :: t()
  def default, do: %__MODULE__{}

  @spec gateway() :: t()
  def gateway, do: default()

  @spec new(keyword() | t()) :: {:ok, t()} | {:error, {:invalid_security_policy, term()}}
  def new(opts \\ [])

  def new(%__MODULE__{} = policy) do
    case validate_values(policy) do
      :ok -> {:ok, policy}
      {:error, reason} -> {:error, {:invalid_security_policy, reason}}
    end
  end

  def new(opts) when is_list(opts) do
    unknown = Keyword.keys(opts) -- @keys

    with [] <- unknown,
         policy <- struct(default(), opts),
         :ok <- validate_values(policy) do
      {:ok, policy}
    else
      [_ | _] = keys -> {:error, {:invalid_security_policy, {:unknown_options, keys}}}
      {:error, reason} -> {:error, {:invalid_security_policy, reason}}
    end
  rescue
    error in [ArgumentError, KeyError] ->
      {:error, {:invalid_security_policy, Exception.message(error)}}
  end

  @spec validate_url(t(), String.t()) :: {:ok, URI.t()} | {:error, {:invalid_url, term()}}
  # Each branch intentionally names the exact rejected URL property.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate_url(%__MODULE__{} = policy, url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, {:invalid_url, {:unsupported_scheme, uri.scheme}}}

      not is_binary(uri.host) or uri.host == "" ->
        {:error, {:invalid_url, :absolute_url_required}}

      not is_nil(uri.userinfo) ->
        {:error, {:invalid_url, :userinfo_not_allowed}}

      not is_nil(uri.fragment) ->
        {:error, {:invalid_url, :fragment_not_allowed}}

      uri.scheme == "http" and not policy.allow_non_loopback_http and not loopback?(uri.host) ->
        {:error, {:invalid_url, {:insecure_scheme, "http"}}}

      true ->
        {:ok, uri}
    end
  end

  def validate_url(%__MODULE__{}, value), do: {:error, {:invalid_url, {:not_a_string, value}}}

  defp validate_values(policy) do
    Enum.find_value(@positive_keys, :ok, fn key ->
      value = Map.fetch!(policy, key)
      if is_integer(value) and value > 0, do: false, else: {:error, {key, value}}
    end)
    |> case do
      :ok -> validate_fixed_values(policy)
      error -> error
    end
  end

  defp validate_fixed_values(policy) do
    cond do
      policy.redirect != :reject ->
        {:error, {:redirect, policy.redirect}}

      policy.retry != false ->
        {:error, {:retry, policy.retry}}

      policy.compression != :disabled ->
        {:error, {:compression, policy.compression}}

      not is_boolean(policy.allow_non_loopback_http) ->
        {:error, {:allow_non_loopback_http, policy.allow_non_loopback_http}}

      true ->
        :ok
    end
  end

  defp loopback?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _other -> false
    end
  end
end
