defmodule MCP.Transport.StreamableHTTPSecurityPolicyTest do
  use ExUnit.Case, async: true

  alias MCP.Transport.StreamableHTTP.Client
  alias MCP.Transport.StreamableHTTP.SecurityPolicy

  test "secure defaults bound requests and reject redirects and retries" do
    policy = SecurityPolicy.default()

    assert policy.redirect == :reject
    assert policy.retry == false
    assert policy.connect_timeout == 5_000
    assert policy.receive_timeout == 30_000
    assert policy.request_timeout == 60_000
    assert policy.max_response_bytes == 1_000_000
    assert policy.max_sse_event_bytes == 1_000_000
    assert policy.compression == :disabled
  end

  test "gateway policy rejects malformed and unsafe endpoint URLs" do
    policy = SecurityPolicy.gateway()

    for url <- [
          "file:///tmp/mcp",
          "/relative/mcp",
          "https://user:pass@example.com/mcp",
          "https://example.com/mcp#fragment",
          "http://example.com/mcp"
        ] do
      assert {:error, _reason} = SecurityPolicy.validate_url(policy, url)
    end

    assert {:ok, %URI{scheme: "http", host: "127.0.0.1"}} =
             SecurityPolicy.validate_url(policy, "http://127.0.0.1:4000/mcp")

    assert {:ok, %URI{scheme: "http", host: "::1"}} =
             SecurityPolicy.validate_url(policy, "http://[::1]:4000/mcp")

    assert {:ok, %URI{scheme: "https", host: "example.com"}} =
             SecurityPolicy.validate_url(policy, "https://example.com/mcp")
  end

  test "the documented localhost endpoint is treated as a loopback destination" do
    policy = SecurityPolicy.gateway()

    for host <- ["localhost", "LocalHost", "localhost.", "api.localhost"] do
      assert {:ok, %URI{scheme: "http"}} =
               SecurityPolicy.validate_url(policy, "http://#{host}:8080/mcp")
    end

    # A name that merely ends in the same letters is not loopback.
    assert {:error, {:invalid_url, {:insecure_scheme, "http"}}} =
             SecurityPolicy.validate_url(policy, "http://notlocalhost:8080/mcp")

    assert {:error, {:invalid_url, {:insecure_scheme, "http"}}} =
             SecurityPolicy.validate_url(policy, "http://localhost.example.com:8080/mcp")
  end

  test "policy construction rejects non-positive bounds and unknown options" do
    assert {:error, {:invalid_security_policy, {:max_response_bytes, 0}}} =
             SecurityPolicy.new(max_response_bytes: 0)

    assert {:error, {:invalid_security_policy, {:unknown_options, [:surprise]}}} =
             SecurityPolicy.new(surprise: true)
  end

  test "client validates the endpoint before starting network work" do
    assert {:error, {{:invalid_url, :userinfo_not_allowed}, _child}} =
             start_supervised({Client, owner: self(), url: "https://user:secret@example.com/mcp"})

    assert {:error, {{:invalid_url, {:insecure_scheme, "http"}}, _child}} =
             start_supervised({Client, owner: self(), url: "http://example.com/mcp"})
  end

  test "explicit policy can permit configured non-loopback development HTTP" do
    assert {:ok, policy} = SecurityPolicy.new(allow_non_loopback_http: true)

    assert {:ok, %URI{host: "dev.internal"}} =
             SecurityPolicy.validate_url(policy, "http://dev.internal/mcp")
  end
end
