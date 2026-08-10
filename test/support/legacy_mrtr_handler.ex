defmodule MCP.Test.LegacyMRTRHandler do
  @moduledoc false
  @behaviour MCP.Server.Handler

  alias MCP.Server.ToolContext

  @impl true
  def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

  @impl true
  def handle_call_tool("many_inputs", _arguments, %ToolContext{input: nil}, _config) do
    requests =
      for index <- 1..33, into: %{} do
        {Integer.to_string(index), %{"method" => "roots/list", "params" => %{}}}
      end

    {:input_required, requests, "many-inputs"}
  end

  def handle_call_tool("parallel_inputs", _arguments, %ToolContext{input: nil}, _config) do
    requests =
      for index <- 1..4, into: %{} do
        {Integer.to_string(index), %{"method" => "roots/list", "params" => %{}}}
      end

    {:input_required, requests, "parallel-inputs"}
  end

  def handle_call_tool("deadline_inputs", _arguments, %ToolContext{input: nil}, _config) do
    requests =
      for index <- 1..12, into: %{} do
        {Integer.to_string(index), %{"method" => "roots/list", "params" => %{}}}
      end

    {:input_required, requests, "deadline-inputs"}
  end

  def handle_call_tool(
        "parallel_inputs",
        _arguments,
        %ToolContext{input: %{responses: responses}},
        config
      ) do
    send(config.test_pid, {:mrtr_responses, responses})
    {:ok, []}
  end
end
