defmodule MCP.Client.ServerResponseDeliveryTest do
  use ExUnit.Case, async: true

  alias MCP.Client.ServerResponseDelivery

  defmodule BlockingTransport do
    def send_message(observer, message) do
      send(observer, {:delivery_started, self(), message})

      receive do
        :release -> :ok
      end
    end
  end

  test "delivery admission is bounded and exposes an absolute deadline" do
    {:ok, supervisor} = Task.Supervisor.start_link(max_children: 1)

    assert {:ok, ref, delivery} =
             ServerResponseDelivery.start(
               supervisor,
               BlockingTransport,
               self(),
               %{"id" => 1},
               25
             )

    assert_receive {:delivery_started, task, %{"id" => 1}}

    assert {:error, :max_children} =
             ServerResponseDelivery.start(
               supervisor,
               BlockingTransport,
               self(),
               %{"id" => 2},
               25
             )

    assert_receive {:server_response_delivery_timeout, ^ref}, 250
    assert :ok = ServerResponseDelivery.cancel(supervisor, delivery)
    refute Process.alive?(task)
  end
end
