defmodule MCP.Transport.StdioTest do
  use ExUnit.Case, async: false

  alias MCP.Test.StdioFixture
  alias MCP.Transport.Stdio

  @echo_server Path.expand("../../support/echo_server.exs", __DIR__)
  @project_dir Path.expand("../../..", __DIR__)

  defp start_echo_transport do
    jason_ebin = Path.join([@project_dir, "_build", "test", "lib", "jason", "ebin"])
    {command, args} = StdioFixture.elixir(["-pa", jason_ebin, @echo_server])

    {:ok, transport} =
      Stdio.start_link(
        owner: self(),
        command: command,
        args: args
      )

    transport
  end

  describe "client mode with echo server" do
    test "sends a request and receives echo response" do
      transport = start_echo_transport()

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "test/echo",
        "params" => %{"hello" => "world"}
      }

      assert :ok = Stdio.send_message(transport, request)

      assert_receive {:mcp_message, response}, 10_000

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["echo"] == %{"hello" => "world"}

      Stdio.close(transport)
    end

    test "handles multiple requests sequentially" do
      transport = start_echo_transport()

      for i <- 1..3 do
        request = %{
          "jsonrpc" => "2.0",
          "id" => i,
          "method" => "test/echo",
          "params" => %{"n" => i}
        }

        assert :ok = Stdio.send_message(transport, request)
      end

      for i <- 1..3 do
        assert_receive {:mcp_message, response}, 10_000
        assert response["id"] == i
        assert response["result"]["echo"]["n"] == i
      end

      Stdio.close(transport)
    end

    test "handles request without params" do
      transport = start_echo_transport()

      request = %{
        "jsonrpc" => "2.0",
        "id" => 42,
        "method" => "ping"
      }

      assert :ok = Stdio.send_message(transport, request)

      assert_receive {:mcp_message, response}, 10_000
      assert response["id"] == 42
      assert response["result"]["echo"] == %{}

      Stdio.close(transport)
    end

    test "notifications get no response" do
      transport = start_echo_transport()

      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      }

      assert :ok = Stdio.send_message(transport, notification)

      # Send a request after to confirm the transport is still working
      request = %{"jsonrpc" => "2.0", "id" => 99, "method" => "test/after"}
      assert :ok = Stdio.send_message(transport, request)

      assert_receive {:mcp_message, response}, 10_000
      assert response["id"] == 99

      Stdio.close(transport)
    end
  end

  describe "server mode" do
    test "close returns the transport contract result" do
      {:ok, transport} = Stdio.start_link(owner: self(), mode: :server)

      assert :ok = Stdio.close(transport)
    end

    test "server mode accepts bounded framing policy configuration" do
      assert {:ok, transport} =
               Stdio.start_link(
                 owner: self(),
                 mode: :server,
                 security_policy: [max_frame_bytes: 64]
               )

      assert :ok = Stdio.close(transport)
    end
  end

  describe "line buffering" do
    test "handles rapid sequential messages" do
      transport = start_echo_transport()

      # Send 5 messages rapidly
      for i <- 1..5 do
        Stdio.send_message(transport, %{
          "jsonrpc" => "2.0",
          "id" => i,
          "method" => "test",
          "params" => %{"i" => i}
        })
      end

      # Collect all responses
      responses =
        for _ <- 1..5 do
          assert_receive {:mcp_message, resp}, 10_000
          resp
        end

      ids = Enum.map(responses, & &1["id"]) |> Enum.sort()
      assert ids == [1, 2, 3, 4, 5]

      Stdio.close(transport)
    end
  end

  describe "process exit" do
    test "notifies owner when subprocess exits" do
      transport = start_echo_transport()

      # Tell the echo server to exit
      Stdio.send_message(transport, %{
        "jsonrpc" => "2.0",
        "method" => "exit"
      })

      assert_receive {:mcp_transport_closed, _reason}, 10_000
    end
  end
end
