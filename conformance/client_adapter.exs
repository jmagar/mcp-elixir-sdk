#!/usr/bin/env elixir

defmodule MCP.Conformance.ClientAdapter do
  @moduledoc false

  alias MCP.Client

  def run do
    url = List.last(System.argv()) || raise "server URL required as the last argument"
    scenario = System.get_env("MCP_CONFORMANCE_SCENARIO") || "tools_call"
    context = decode_context(System.get_env("MCP_CONFORMANCE_CONTEXT"))

    IO.puts("Scenario: #{scenario}")
    IO.puts("Server URL: #{url}")

    {:ok, client} = start_client(url)

    try do
      {:ok, _discover} = Client.connect(client)
      run_scenario(scenario, client, context)
    after
      Client.close(client)
    end

    IO.puts("Scenario '#{scenario}' completed successfully")
  end

  defp run_scenario("tools_call", client, _context) do
    {:ok, _tools} = Client.list_tools(client)
    {:ok, _result} = Client.call_tool(client, "add_numbers", %{"a" => 20, "b" => 22})
  end

  defp run_scenario("initialize", _client, _context), do: :ok

  defp run_scenario("elicitation-sep1034-client-defaults", client, _context) do
    {:ok, _tools} = Client.list_tools(client)
    {:ok, _result} = Client.call_tool(client, "test_client_elicitation_defaults", %{})
  end

  defp run_scenario("request-metadata", client, _context) do
    {:ok, _tools} = Client.list_tools(client)
  end

  defp run_scenario("sep-2322-client-request-state", client, _context) do
    {:ok, _tools} = Client.list_tools(client)

    for name <- [
          "test_mrtr_echo_state",
          "test_mrtr_no_state",
          "test_mrtr_unrelated",
          "test_mrtr_no_result_type"
        ] do
      {:ok, _result} = Client.call_tool(client, name, %{})
    end
  end

  defp run_scenario("http-standard-headers", client, _context) do
    {:ok, %{"tools" => [tool | _]}} = Client.list_tools(client)
    {:ok, _result} = Client.call_tool(client, tool["name"], %{})

    {:ok, %{"resources" => [resource | _]}} = Client.list_resources(client)
    {:ok, _result} = Client.read_resource(client, resource["uri"])

    {:ok, %{"prompts" => [prompt | _]}} = Client.list_prompts(client)
    {:ok, _result} = Client.get_prompt(client, prompt["name"], %{})
  end

  defp run_scenario("http-custom-headers", client, context) do
    {:ok, _tools} = Client.list_tools(client)

    context
    |> Map.get("toolCalls", [])
    |> Enum.each(fn %{"name" => name, "arguments" => arguments} ->
      {:ok, _result} = Client.call_tool(client, name, arguments)
    end)
  end

  defp run_scenario("http-invalid-tool-headers", client, _context) do
    {:ok, %{"tools" => tools}} = Client.list_tools(client)
    true = Enum.any?(tools, &(&1["name"] == "valid_tool"))
    false = Enum.any?(tools, &String.starts_with?(&1["name"], "invalid_"))
    {:ok, _result} = Client.call_tool(client, "valid_tool", %{"region" => "us-east1"})
  end

  defp run_scenario("json-schema-ref-no-deref", client, _context) do
    {:ok, _tools} = Client.list_tools(client)
  end

  defp run_scenario("json-schema-2020-12-preservation", client, _context) do
    {:ok, %{"tools" => tools}} = Client.list_tools(client)
    focal = Enum.find(tools, &(&1["name"] == "json_schema_2020_12_tool"))

    {:ok, _result} =
      Client.call_tool(client, "json_schema_echo", %{"schema" => focal["inputSchema"]})
  end

  defp run_scenario(other, _client, _context), do: raise("unsupported scenario: #{other}")

  defp start_client(url) do
    protocol_version = System.get_env("MCP_CONFORMANCE_PROTOCOL_VERSION") || "2026-07-28"

    Client.start_link(
      transport: {MCP.Transport.StreamableHTTP.Client, url: url, headers: []},
      protocol_version: protocol_version,
      client_info: %{name: "mcp_elixir_sdk_conformance", version: "2.0.0-dev.2"},
      client_capabilities: %{
        "sampling" => %{},
        "elicitation" => %{},
        "roots" => %{"listChanged" => true}
      },
      on_input_required: &resolve_input_requests/1,
      on_sampling: &handle_sampling/1,
      on_roots_list: fn _params ->
        {:ok, %{"roots" => [%{"uri" => "file:///conformance", "name" => "conformance"}]}}
      end,
      on_elicitation: &handle_elicitation/1
    )
  end

  defp handle_sampling(_params) do
    {:ok,
     %{
       "role" => "assistant",
       "content" => %{"type" => "text", "text" => "Conformance response"},
       "model" => "conformance-test",
       "stopReason" => "endTurn"
     }}
  end

  defp handle_elicitation(params) do
    properties = get_in(params, ["requestedSchema", "properties"]) || %{}

    content =
      Map.new(properties, fn {name, schema} ->
        value =
          cond do
            Map.has_key?(schema, "default") -> schema["default"]
            is_list(schema["enum"]) -> List.first(schema["enum"])
            is_list(schema["oneOf"]) -> schema["oneOf"] |> List.first() |> Map.get("const")
            schema["type"] == "array" -> []
            schema["type"] == "boolean" -> false
            schema["type"] in ["integer", "number"] -> 0
            true -> "conformance"
          end

        {name, value}
      end)

    {:ok, %{"action" => "accept", "content" => content}}
  end

  defp resolve_input_requests(requests) do
    Map.new(requests, fn {key, request} ->
      response =
        case request["method"] do
          "sampling/createMessage" ->
            %{
              "role" => "assistant",
              "content" => %{"type" => "text", "text" => "Conformance response"},
              "model" => "conformance-test",
              "stopReason" => "endTurn"
            }

          "roots/list" ->
            %{"roots" => [%{"uri" => "file:///conformance", "name" => "conformance"}]}

          _elicitation ->
            %{"action" => "accept", "content" => %{"confirmed" => true}}
        end

      {key, response}
    end)
  end

  defp decode_context(nil), do: %{}

  defp decode_context(json) do
    case Jason.decode(json) do
      {:ok, context} when is_map(context) -> context
      _ -> %{}
    end
  end
end

MCP.Conformance.ClientAdapter.run()
