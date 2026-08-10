defmodule MCP.Test.RedirectPolicyPlug do
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["redirect", status]} = conn, _opts) do
    location = "http://127.0.0.1:#{conn.port}/target?secret=location-secret"

    conn
    |> Plug.Conn.put_resp_header("location", location)
    |> Plug.Conn.send_resp(String.to_integer(status), "redirect")
  end

  def call(%Plug.Conn{path_info: ["target"]} = conn, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:redirect_target_reached, conn.req_headers})
    Plug.Conn.send_resp(conn, 200, "unexpected")
  end
end

defmodule MCP.Transport.StreamableHTTPResponseBoundsTest do
  use ExUnit.Case, async: true

  alias MCP.Transport.StreamableHTTP.ResponseReader
  alias MCP.Transport.StreamableHTTP.SecurityPolicy

  test "redirects are rejected without contacting the target or forwarding secrets" do
    bandit =
      start_supervised!(
        {Bandit,
         plug: {MCP.Test.RedirectPolicyPlug, test_pid: self()}, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    for status <- [301, 302, 303, 307, 308] do
      assert {:error, {:redirect_rejected, ^status, sanitized}} =
               ResponseReader.request(
                 [
                   method: :post,
                   url: "http://127.0.0.1:#{port}/redirect/#{status}",
                   headers: [{"x-api-key", "never-forward"}],
                   body: "{}"
                 ],
                 SecurityPolicy.default()
               )

      refute sanitized =~ "location-secret"
      refute_receive {:redirect_target_reached, _headers}, 10
    end
  end

  test "finite consumption cancels as soon as a chunk crosses the byte limit" do
    {response, ref} = async_response()
    send(self(), {ref, {:data, "1234"}})
    send(self(), {ref, {:data, "56"}})

    assert {:error, {:response_too_large, 5}} = ResponseReader.consume(response, 5, 100)
    assert_receive {:cancelled, ^ref}
  end

  test "finite consumption returns only after done" do
    {response, ref} = async_response()
    send(self(), {ref, {:data, "12"}})
    send(self(), {ref, {:data, "34"}})
    send(self(), {ref, :done})

    assert {:ok, "1234"} = ResponseReader.consume(response, 4, 100)
  end

  test "idle timeout cancels the response" do
    {response, ref} = async_response()

    assert {:error, :receive_timeout} = ResponseReader.consume(response, 5, 1)
    assert_receive {:cancelled, ^ref}
  end

  defp async_response do
    ref = make_ref()
    owner = self()

    stream_fun = fn
      ^ref, {^ref, {:data, data}} -> {:ok, [data: data]}
      ^ref, {^ref, :done} -> {:ok, [:done]}
      ^ref, _message -> :unknown
    end

    cancel_fun = fn ^ref -> send(owner, {:cancelled, ref}) end

    async = %Req.Response.Async{
      pid: self(),
      ref: ref,
      stream_fun: stream_fun,
      cancel_fun: cancel_fun
    }

    {%Req.Response{status: 200, headers: %{}, body: async}, ref}
  end
end
