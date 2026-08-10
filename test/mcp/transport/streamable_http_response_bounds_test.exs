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

defmodule MCP.Test.BoundedResponsePlug do
  @behaviour Plug
  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, chunks: chunks) do
    conn = Plug.Conn.send_chunked(conn, 200)

    Enum.reduce_while(chunks, conn, fn {delay, chunk}, current ->
      Process.sleep(delay)

      case Plug.Conn.chunk(current, chunk) do
        {:ok, next} -> {:cont, next}
        {:error, _reason} -> {:halt, current}
      end
    end)
  end

  def call(conn, opts) do
    body = Keyword.fetch!(opts, :body)
    content_type = Keyword.get(opts, :content_type, "text/event-stream")

    conn
    |> Plug.Conn.put_resp_content_type(content_type)
    |> Plug.Conn.send_resp(200, body)
  end
end

defmodule MCP.Transport.StreamableHTTPResponseBoundsTest do
  use ExUnit.Case, async: false

  alias MCP.Transport.StreamableHTTP.Client
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
    end

    refute_receive {:redirect_target_reached, _headers}, 250
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

  test "finite POST SSE enforces the event bound before JSON delivery" do
    oversized =
      "data: " <>
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => String.duplicate("x", 80)}) <>
        "\n\n"

    url = start_response_server(oversized)
    {:ok, policy} = SecurityPolicy.new(max_response_bytes: 1_000, max_sse_event_bytes: 32)
    client = start_supervised!({Client, owner: self(), url: url, security_policy: policy})

    assert {:error, :event_too_large} =
             Client.send_message(client, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    refute_receive {:mcp_message, _}
  end

  test "finite POST SSE reports malformed JSON instead of silently timing out" do
    url = start_response_server("data: not-json\n\n")
    client = start_supervised!({Client, owner: self(), url: url})

    assert {:error, {:invalid_sse_json, %Jason.DecodeError{}}} =
             Client.send_message(client, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
  end

  test "an absolute request deadline stops a peer that continuously drips chunks" do
    bandit =
      start_supervised!(
        {Bandit,
         plug: {MCP.Test.BoundedResponsePlug, chunks: List.duplicate({30, "x"}, 10)},
         ip: {127, 0, 0, 1},
         port: 0},
        id: {MCP.Test.BoundedResponsePlug, make_ref()}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    {:ok, policy} = SecurityPolicy.new(receive_timeout: 50, request_timeout: 100)

    assert {:error, :request_timeout} =
             ResponseReader.request([url: "http://127.0.0.1:#{port}/mcp"], policy)
  end

  defp start_response_server(body) do
    bandit =
      start_supervised!(
        {Bandit, plug: {MCP.Test.BoundedResponsePlug, body: body}, ip: {127, 0, 0, 1}, port: 0},
        id: {MCP.Test.BoundedResponsePlug, make_ref()}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    "http://127.0.0.1:#{port}/mcp"
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
