defmodule MCP.Protocol.RevisionTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Legacy.V2025_11_25
  alias MCP.Protocol.Revision
  alias MCP.Test.MockTransport

  @client_info %{name: "client", version: "1.0.0"}

  test "lists supported revisions in preference order" do
    assert Revision.supported() == ["2026-07-28", "2025-11-25"]
  end

  test "fetches version-isolated legacy adapters without creating atoms" do
    assert {:ok, V2025_11_25} = Revision.fetch("2025-11-25")

    assert {:error, {:unsupported_protocol_version, "2025-06-18"}} =
             Revision.fetch("2025-06-18")

    assert {:error, {:unsupported_protocol_version, "bogus"}} =
             Revision.fetch("bogus")
  end

  test "the legacy adapter builds and validates its exact initialize revision" do
    params = V2025_11_25.initialize_params(@client_info, %{})

    assert params["protocolVersion"] == V2025_11_25.version()
    assert params["clientInfo"] == %{"name" => "client", "version" => "1.0.0"}
    assert params["capabilities"] == %{}
    assert V2025_11_25.http_session?()

    assert :ok =
             V2025_11_25.validate_initialize_result(%{
               "protocolVersion" => V2025_11_25.version()
             })

    assert {:error, {:unexpected_protocol_version, "other"}} =
             V2025_11_25.validate_initialize_result(%{"protocolVersion" => "other"})
  end

  test "modern revision is registered without a legacy adapter" do
    assert {:ok, :stateless} = Revision.fetch("2026-07-28")
  end

  test "client startup rejects an unsupported configured revision" do
    assert {:error, {:unsupported_protocol_version, "bogus"}} =
             GenServer.start(MCP.Client,
               transport: {MockTransport, []},
               protocol_version: "bogus"
             )
  end
end
