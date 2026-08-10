defmodule MCP.Protocol.RevisionTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Legacy.{V2025_06_18, V2025_11_25}
  alias MCP.Protocol.Revision
  alias MCP.Test.MockTransport

  @client_info %{name: "client", version: "1.0.0"}

  test "lists supported revisions in preference order" do
    assert Revision.supported() == ["2026-07-28", "2025-11-25", "2025-06-18"]
  end

  test "fetches version-isolated legacy adapters without creating atoms" do
    assert {:ok, V2025_11_25} = Revision.fetch("2025-11-25")
    assert {:ok, V2025_06_18} = Revision.fetch("2025-06-18")

    assert {:error, {:unsupported_protocol_version, "bogus"}} =
             Revision.fetch("bogus")
  end

  test "legacy adapters build and validate their exact initialize revision" do
    for adapter <- [V2025_11_25, V2025_06_18] do
      params = adapter.initialize_params(@client_info, %{})

      assert params["protocolVersion"] == adapter.version()
      assert params["clientInfo"] == %{"name" => "client", "version" => "1.0.0"}
      assert params["capabilities"] == %{}
      assert adapter.http_session?()
      assert :ok = adapter.validate_initialize_result(%{"protocolVersion" => adapter.version()})

      assert {:error, {:unexpected_protocol_version, "other"}} =
               adapter.validate_initialize_result(%{"protocolVersion" => "other"})
    end
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
