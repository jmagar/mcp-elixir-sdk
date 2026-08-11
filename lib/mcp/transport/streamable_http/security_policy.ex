defmodule MCP.Transport.StreamableHTTP.SecurityPolicy do
  @moduledoc """
  Validated security and resource policy for Streamable HTTP clients.

  Defaults reject redirects, retries, unbounded responses, and plaintext HTTP
  outside loopback destinations.
  """

  defstruct connect_timeout: 5_000,
            receive_timeout: 30_000,
            request_timeout: 60_000,
            max_response_bytes: 1_000_000,
            max_decoded_response_bytes: 1_000_000,
            max_sse_event_bytes: 1_000_000,
            max_concurrent_requests: 64,
            max_subscriptions: 64,
            allow_non_loopback_http: false

  @type t :: %__MODULE__{
          connect_timeout: pos_integer(),
          receive_timeout: pos_integer(),
          request_timeout: pos_integer(),
          max_response_bytes: pos_integer(),
          max_decoded_response_bytes: pos_integer(),
          max_sse_event_bytes: pos_integer(),
          max_concurrent_requests: pos_integer(),
          max_subscriptions: pos_integer(),
          allow_non_loopback_http: boolean()
        }

  @keys [
    :connect_timeout,
    :receive_timeout,
    :request_timeout,
    :max_response_bytes,
    :max_decoded_response_bytes,
    :max_sse_event_bytes,
    :max_concurrent_requests,
    :max_subscriptions,
    :allow_non_loopback_http
  ]
  @positive_keys [
    :connect_timeout,
    :receive_timeout,
    :request_timeout,
    :max_response_bytes,
    :max_decoded_response_bytes,
    :max_sse_event_bytes,
    :max_concurrent_requests,
    :max_subscriptions
  ]

  @spec default() :: t()
  def default, do: %__MODULE__{}

  @spec gateway() :: t()
  def gateway, do: default()

  @doc "Returns the effective body limit while response compression is disabled."
  @spec response_limit(t()) :: pos_integer()
  def response_limit(%__MODULE__{} = policy),
    do: min(policy.max_response_bytes, policy.max_decoded_response_bytes)

  @doc "Returns the connect timeout constrained by the whole-request budget."
  @spec connection_timeout(t()) :: pos_integer()
  def connection_timeout(%__MODULE__{} = policy),
    do: min(policy.connect_timeout, policy.request_timeout)

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
    if is_boolean(policy.allow_non_loopback_http) do
      :ok
    else
      {:error, {:allow_non_loopback_http, policy.allow_non_loopback_http}}
    end
  end

  defp loopback?(host) do
    loopback_name?(host) or loopback_address?(host)
  end

  # RFC 6761 reserves `localhost` (and any name under it) to resolve to a
  # loopback address, so the documented `http://localhost:8080/mcp` endpoint is
  # a loopback destination even though it is not an IP literal.
  defp loopback_name?(host) do
    normalized = host |> String.downcase() |> String.trim_trailing(".")
    normalized == "localhost" or String.ends_with?(normalized, ".localhost")
  end

  defp loopback_address?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _other -> false
    end
  end
end
