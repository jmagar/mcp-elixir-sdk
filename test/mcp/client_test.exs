defmodule MCP.ClientTest do
  @moduledoc """
  MES-9 — the stateless `MCP.Client`: no `initialize` handshake, ready by
  default, `server/discover` capability probe, per-request `_meta`, and MRTR
  client-retry. Driven in isolation via `MockTransport`.

  The 2025-11-25 server→client request handling (client-side sampling / roots /
  elicitation callbacks) is removed with the held-open request path (D-B); its
  replacement is the MRTR `:on_input_required` resolver, exercised below.
  """
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Test.MockTransport

  @server_info %{"name" => "test-server", "version" => "1.0.0"}
  @server_capabilities %{
    "tools" => %{"listChanged" => true},
    "resources" => %{"listChanged" => true},
    "prompts" => %{"listChanged" => true}
  }

  defp wait_for_sent(transport, count, timeout \\ 1000) do
    case MockTransport.await_sent(transport, count, timeout) do
      {:ok, messages} -> messages
      {:error, :timeout} -> flunk("Timed out waiting for #{count} messages")
    end
  end

  defp start_client(opts \\ []) do
    {:ok, client} =
      Client.start_link(
        Keyword.merge(
          [transport: {MockTransport, []}, client_info: %{name: "test-client", version: "0.1.0"}],
          opts
        )
      )

    {client, Client.transport(client)}
  end

  # connect → one sent message (server/discover). Inject the discover result.
  defp do_connect(client, transport) do
    task = Task.async(fn -> Client.connect(client) end)
    [discover] = wait_for_sent(transport, 1)
    assert discover["method"] == "server/discover"

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => discover["id"],
      "result" => %{
        "supportedVersions" => ["2026-07-28"],
        "capabilities" => @server_capabilities,
        "resultType" => "complete",
        "ttlMs" => 0,
        "cacheScope" => "public",
        "_meta" => %{"io.modelcontextprotocol/serverInfo" => @server_info}
      }
    })

    {:ok, result} = Task.await(task)
    assert result.server_info.name == "test-server"
    :ok
  end

  # The Nth request after connect is sent message index N (connect is 0).
  defp last_after_connect(transport, n) do
    messages = wait_for_sent(transport, 1 + n)
    List.last(messages)
  end

  describe "start_link/1" do
    test "starts ready by default (no handshake gate)" do
      {client, transport} = start_client()
      assert is_pid(client)
      assert is_pid(transport)
      assert Client.status(client) == :ready
    end

    test "rejects a negative tool schema limit at startup" do
      assert {:error, {:invalid_tool_schema_limit, -1}} =
               Client.start_link(
                 transport: {MockTransport, []},
                 client_info: %{name: "test-client", version: "0.1.0"},
                 tool_schema_limit: -1
               )
    end

    test "rejects an invalid notification concurrency limit at startup" do
      assert {:error, {:invalid_notification_concurrency, 0}} =
               Client.start_link(
                 transport: {MockTransport, []},
                 notification_concurrency: 0
               )
    end
  end

  describe "connect/1 (server/discover)" do
    test "probes capabilities and returns server info" do
      {client, transport} = start_client()
      task = Task.async(fn -> Client.connect(client) end)

      [discover] = wait_for_sent(transport, 1)
      assert discover["method"] == "server/discover"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => discover["id"],
        "result" => %{
          "supportedVersions" => ["2026-07-28"],
          "capabilities" => @server_capabilities,
          "resultType" => "complete",
          "ttlMs" => 0,
          "cacheScope" => "public",
          "_meta" => %{"io.modelcontextprotocol/serverInfo" => @server_info}
        }
      })

      {:ok, result} = Task.await(task)
      assert result.server_info.name == "test-server"
      assert result.server_capabilities.tools != nil
      assert result.protocol_version == "2026-07-28"
    end

    test "returns error on discover failure" do
      {client, transport} = start_client()
      task = Task.async(fn -> Client.connect(client) end)
      [discover] = wait_for_sent(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => discover["id"],
        "error" => %{"code" => -32_603, "message" => "Internal error"}
      })

      {:error, error} = Task.await(task)
      assert error.code == -32_603
    end

    test "retries discover once using a server-supported protocol version" do
      {client, transport} = start_client()
      task = Task.async(fn -> Client.connect(client) end)
      [first] = wait_for_sent(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => first["id"],
        "error" => %{
          "code" => -32_022,
          "message" => "Unsupported protocol version",
          "data" => %{"supported" => ["2026-07-28"], "requested" => "2026-07-28"}
        }
      })

      [_first, retry] = wait_for_sent(transport, 2)
      assert retry["method"] == "server/discover"
      assert retry["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => retry["id"],
        "result" => %{
          "supportedVersions" => ["2026-07-28"],
          "capabilities" => %{},
          "resultType" => "complete",
          "ttlMs" => 0,
          "cacheScope" => "public",
          "_meta" => %{"io.modelcontextprotocol/serverInfo" => @server_info}
        }
      })

      assert {:ok, %{protocol_version: "2026-07-28"}} = Task.await(task)
    end

    test "negotiates down to the supported 2025-11-25 protocol revision" do
      {client, transport} = start_client()
      task = Task.async(fn -> Client.connect(client) end)
      [first] = wait_for_sent(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => first["id"],
        "error" => %{
          "code" => -32_022,
          "message" => "Unsupported protocol version",
          "data" => %{"supported" => ["2025-11-25"]}
        }
      })

      [_discover, initialize] = wait_for_sent(transport, 2)
      assert initialize["method"] == "initialize"
      assert initialize["params"]["protocolVersion"] == "2025-11-25"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => initialize["id"],
        "result" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "serverInfo" => @server_info
        }
      })

      assert {:ok, %{protocol_version: "2025-11-25"}} = Task.await(task)
      assert length(MockTransport.sent_messages(transport)) == 3
      assert Client.status(client) == :ready
    end

    test "rejects malformed discovery results without terminating the client" do
      {client, transport} = start_client()
      task = Task.async(fn -> Client.connect(client) end)
      [request] = wait_for_sent(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{
          "supportedVersions" => ["2026-07-28"],
          "capabilities" => %{"extensions" => %{"tasks" => %{}}}
        }
      })

      assert {:error, {:invalid_discover_result, _reason}} = Task.await(task)
      assert Client.status(client) == :ready
    end
  end

  describe "timeout validation" do
    test "invalid per-call and connect timeouts do not terminate the client" do
      {client, _transport} = start_client()

      for timeout <- [-1, :infinity, "soon"] do
        assert Client.connect(client, timeout) == {:error, {:invalid_timeout, timeout}}

        assert Client.list_tools(client, timeout: timeout) ==
                 {:error, {:invalid_timeout, timeout}}
      end

      assert Client.status(client) == :ready
    end
  end

  describe "per-request _meta" do
    test "accepts string-keyed capability maps at the public API" do
      {client, transport} =
        start_client(
          client_capabilities: %{
            "sampling" => %{},
            "elicitation" => %{},
            "roots" => %{"listChanged" => true}
          }
        )

      do_connect(client, transport)
      [request] = MockTransport.sent_messages(transport)
      capabilities = request["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"]

      assert capabilities == %{
               "sampling" => %{},
               "elicitation" => %{},
               "roots" => %{"listChanged" => true}
             }
    end

    test "every request carries protocolVersion + client identity/capabilities" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_tools(client) end)
      req = last_after_connect(transport, 1)

      meta = req["params"]["_meta"]
      assert meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
      assert meta["io.modelcontextprotocol/clientInfo"]["name"] == "test-client"
      assert is_map(meta["io.modelcontextprotocol/clientCapabilities"])

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "result" => %{"tools" => []}
      })

      {:ok, _} = Task.await(task)
    end
  end

  describe "requests" do
    test "list_tools returns tools" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_tools(client) end)
      req = last_after_connect(transport, 1)
      assert req["method"] == "tools/list"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "result" => %{
          "tools" => [%{"name" => "echo", "inputSchema" => %{"type" => "object"}}]
        }
      })

      {:ok, result} = Task.await(task)
      assert hd(result["tools"])["name"] == "echo"
    end

    test "list_tools excludes only the tool with x-mcp-header in a forbidden location" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_tools(client) end)
      req = last_after_connect(transport, 1)

      valid = %{
        "name" => "weather",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "region" => %{"type" => "string", "x-mcp-header" => "Region"}
          }
        }
      }

      invalid = %{
        "name" => "batch_weather",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "regions" => %{
              "type" => "array",
              "items" => %{"type" => "string", "x-mcp-header" => "Region"}
            }
          }
        }
      }

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "result" => %{"tools" => [valid, invalid]}
      })

      assert {:ok, %{"tools" => [^valid]}} = Task.await(task)
    end

    test "list_tools excludes a tool whose x-mcp-header name is not an HTTP token" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_tools(client) end)
      req = last_after_connect(transport, 1)

      invalid = %{
        "name" => "weather",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "region" => %{"type" => "string", "x-mcp-header" => "Bad Header"}
          }
        }
      }

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "result" => %{"tools" => [invalid]}
      })

      assert {:ok, %{"tools" => []}} = Task.await(task)
    end

    test "list_tools excludes a tool with case-insensitively duplicate header names" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_tools(client) end)
      req = last_after_connect(transport, 1)

      invalid = %{
        "name" => "weather",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "region" => %{"type" => "string", "x-mcp-header" => "Region"},
            "fallback" => %{"type" => "string", "x-mcp-header" => "REGION"}
          }
        }
      }

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "result" => %{"tools" => [invalid]}
      })

      assert {:ok, %{"tools" => []}} = Task.await(task)
    end

    test "list_tools excludes a tool whose annotated property has an unsupported type" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_tools(client) end)
      req = last_after_connect(transport, 1)

      invalid = %{
        "name" => "weather",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "temperature" => %{"type" => "number", "x-mcp-header" => "Temperature"}
          }
        }
      }

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "result" => %{"tools" => [invalid]}
      })

      assert {:ok, %{"tools" => []}} = Task.await(task)
    end

    test "list_tools excludes malformed catalog entries without terminating the client" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_tools(client) end)
      req = last_after_connect(transport, 1)
      valid = %{"name" => "echo", "inputSchema" => %{"type" => "object"}}

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "result" => %{"tools" => [nil, %{"description" => "missing name"}, valid]}
      })

      assert {:ok, %{"tools" => [^valid]}} = Task.await(task)
      assert Client.status(client) == :ready
    end

    test "list_tools rejects malformed result containers without terminating the client" do
      for invalid_result <- [%{"tools" => nil}, %{"tools" => %{}}, []] do
        {client, transport} = start_client()
        do_connect(client, transport)
        task = Task.async(fn -> Client.list_tools(client) end)
        req = last_after_connect(transport, 1)

        MockTransport.inject(transport, %{
          "jsonrpc" => "2.0",
          "id" => req["id"],
          "result" => invalid_result
        })

        assert {:error, {:invalid_tools_result, _reason}} = Task.await(task)
        assert Client.status(client) == :ready
      end
    end

    test "malformed JSON-RPC errors do not terminate the client" do
      # Keep the timeout short enough to exercise the malformed-response path,
      # but long enough that connection setup cannot consume it under a loaded
      # test scheduler.
      {client, transport} = start_client(request_timeout: 250)
      do_connect(client, transport)
      task = Task.async(fn -> Client.list_tools(client) end)
      req = last_after_connect(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "error" => "scalar"
      })

      assert {:error, :timeout} = Task.await(task, 1_000)
      assert Client.status(client) == :ready
    end

    test "list_tools requires an object-root inputSchema" do
      {client, transport} = start_client()
      do_connect(client, transport)
      task = Task.async(fn -> Client.list_tools(client) end)
      req = last_after_connect(transport, 1)
      valid = %{"name" => "valid", "inputSchema" => %{"type" => "object"}}

      invalid = [
        %{"name" => "missing"},
        %{"name" => "boolean", "inputSchema" => true},
        %{"name" => "untyped", "inputSchema" => %{}},
        %{"name" => "scalar", "inputSchema" => %{"type" => "string"}}
      ]

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "result" => %{"tools" => invalid ++ [valid]}
      })

      assert {:ok, %{"tools" => [^valid]}} = Task.await(task)
      assert Client.status(client) == :ready
    end

    test "call_tool sends name and arguments" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.call_tool(client, "echo", %{"message" => "hi"}) end)
      req = last_after_connect(transport, 1)
      assert req["method"] == "tools/call"
      assert req["params"]["name"] == "echo"
      assert req["params"]["arguments"] == %{"message" => "hi"}

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "result" => %{"content" => [%{"type" => "text", "text" => "hi"}]}
      })

      {:ok, result} = Task.await(task)
      assert hd(result["content"])["text"] == "hi"
    end

    test "call_tool passes cached validated header descriptors to a capable transport" do
      {client, transport} = start_client()
      do_connect(client, transport)

      list_task = Task.async(fn -> Client.list_tools(client) end)
      list_req = last_after_connect(transport, 1)

      tool = %{
        "name" => "weather",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "region" => %{"type" => "string", "x-mcp-header" => "Region"}
          }
        }
      }

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => list_req["id"],
        "result" => %{"tools" => [tool]}
      })

      assert {:ok, %{"tools" => [^tool]}} = Task.await(list_task)

      call_task =
        Task.async(fn -> Client.call_tool(client, "weather", %{"region" => "us-east"}) end)

      call_req = last_after_connect(transport, 2)

      assert MockTransport.last_send_options(transport) == [
               routing_headers: [%{header: "Region", path: ["region"], type: "string"}]
             ]

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => call_req["id"],
        "result" => %{"content" => []}
      })

      assert {:ok, %{"content" => []}} = Task.await(call_task)
    end

    test "call_tool accepts an explicit input schema without populating the catalog first" do
      {client, transport} = start_client()
      do_connect(client, transport)

      schema = %{
        "type" => "object",
        "properties" => %{
          "region" => %{"type" => "string", "x-mcp-header" => "Region"}
        }
      }

      task =
        Task.async(fn ->
          Client.call_tool(client, "weather", %{"region" => "east"}, input_schema: schema)
        end)

      req = last_after_connect(transport, 1)

      assert MockTransport.last_send_options(transport) == [
               routing_headers: [%{header: "Region", path: ["region"], type: "string"}]
             ]

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "result" => %{"content" => []}
      })

      assert {:ok, %{"content" => []}} = Task.await(task)
    end

    test "tool schema index evicts the least recently indexed tool at its configured bound" do
      {client, transport} = start_client(tool_schema_limit: 1)
      do_connect(client, transport)

      list_task = Task.async(fn -> Client.list_tools(client) end)
      list_req = last_after_connect(transport, 1)

      tool = fn name, header ->
        %{
          "name" => name,
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "value" => %{"type" => "string", "x-mcp-header" => header}
            }
          }
        }
      end

      first = tool.("first", "First")
      second = tool.("second", "Second")

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => list_req["id"],
        "result" => %{"tools" => [first, second]}
      })

      assert {:ok, _result} = Task.await(list_task)

      first_task = Task.async(fn -> Client.call_tool(client, "first", %{"value" => "a"}) end)
      first_req = last_after_connect(transport, 2)
      assert MockTransport.last_send_options(transport) == [routing_headers: []]

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => first_req["id"],
        "result" => %{"content" => []}
      })

      assert {:ok, _result} = Task.await(first_task)

      second_task = Task.async(fn -> Client.call_tool(client, "second", %{"value" => "b"}) end)
      second_req = last_after_connect(transport, 3)

      assert MockTransport.last_send_options(transport) == [
               routing_headers: [%{header: "Second", path: ["value"], type: "string"}]
             ]

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => second_req["id"],
        "result" => %{"content" => []}
      })

      assert {:ok, _result} = Task.await(second_task)
    end

    test "recognized custom HeaderMismatch refreshes schemas and retries the call only once" do
      {client, transport} = start_client()
      do_connect(client, transport)

      tool = fn header ->
        %{
          "name" => "weather",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "region" => %{"type" => "string", "x-mcp-header" => header}
            }
          }
        }
      end

      list_task = Task.async(fn -> Client.list_tools(client) end)
      list_req = last_after_connect(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => list_req["id"],
        "result" => %{"tools" => [tool.("Region")]}
      })

      assert {:ok, _result} = Task.await(list_task)

      call_task = Task.async(fn -> Client.call_tool(client, "weather", %{"region" => "east"}) end)
      first_call = last_after_connect(transport, 2)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => first_call["id"],
        "error" => %{
          "code" => -32_020,
          "message" => "Header mismatch",
          "data" => "mcp-param-region mismatch"
        }
      })

      refresh = last_after_connect(transport, 3)
      assert refresh["method"] == "tools/list"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => refresh["id"],
        "result" => %{"tools" => [tool.("Zone")]}
      })

      retry = last_after_connect(transport, 4)
      assert retry["method"] == "tools/call"

      assert MockTransport.last_send_options(transport) == [
               routing_headers: [%{header: "Zone", path: ["region"], type: "string"}]
             ]

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => retry["id"],
        "error" => %{
          "code" => -32_020,
          "message" => "Header mismatch",
          "data" => "mcp-param-zone mismatch"
        }
      })

      assert {:error, error} = Task.await(call_task)
      assert error.code == -32_020
      assert length(MockTransport.sent_messages(transport)) == 5
    end

    test "an evicted annotated tool refreshes and retries with reacquired descriptors" do
      {client, transport} = start_client(tool_schema_limit: 1)
      do_connect(client, transport)

      tool = fn name, header ->
        %{
          "name" => name,
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "value" => %{"type" => "string", "x-mcp-header" => header}
            }
          }
        }
      end

      first = tool.("first", "First")
      second = tool.("second", "Second")
      list_task = Task.async(fn -> Client.list_tools(client) end)
      list_req = last_after_connect(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => list_req["id"],
        "result" => %{"tools" => [first, second]}
      })

      assert {:ok, _result} = Task.await(list_task)

      call_task = Task.async(fn -> Client.call_tool(client, "first", %{"value" => "a"}) end)
      first_call = last_after_connect(transport, 2)
      assert MockTransport.last_send_options(transport) == [routing_headers: []]

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => first_call["id"],
        "error" => %{
          "code" => -32_020,
          "message" => "Header mismatch",
          "data" => "missing mcp-param-first header"
        }
      })

      refresh = last_after_connect(transport, 3)
      assert refresh["method"] == "tools/list"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => refresh["id"],
        "result" => %{"tools" => [first, second]}
      })

      retry = last_after_connect(transport, 4)

      assert MockTransport.last_send_options(transport) == [
               routing_headers: [%{header: "First", path: ["value"], type: "string"}]
             ]

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => retry["id"],
        "result" => %{"content" => []}
      })

      assert {:ok, %{"content" => []}} = Task.await(call_task)
    end

    test "schema refresh paginates until it reacquires the selected tool" do
      {client, transport} = start_client()
      do_connect(client, transport)

      tool = fn header ->
        %{
          "name" => "weather",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "region" => %{"type" => "string", "x-mcp-header" => header}
            }
          }
        }
      end

      page_task = Task.async(fn -> Client.list_tools(client, cursor: "page-2") end)
      page_req = last_after_connect(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => page_req["id"],
        "result" => %{"tools" => [tool.("Region")]}
      })

      assert {:ok, _result} = Task.await(page_task)

      call_task = Task.async(fn -> Client.call_tool(client, "weather", %{"region" => "east"}) end)
      first_call = last_after_connect(transport, 2)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => first_call["id"],
        "error" => %{
          "code" => -32_020,
          "message" => "Header mismatch",
          "data" => "mcp-param-region mismatch"
        }
      })

      refresh_page_1 = last_after_connect(transport, 3)
      assert refresh_page_1["params"]["cursor"] == nil

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => refresh_page_1["id"],
        "result" => %{"tools" => [%{"name" => "other"}], "nextCursor" => "next"}
      })

      refresh_page_2 = last_after_connect(transport, 4)
      assert refresh_page_2["params"]["cursor"] == "next"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => refresh_page_2["id"],
        "result" => %{"tools" => [tool.("Zone")]}
      })

      retry = last_after_connect(transport, 5)

      assert MockTransport.last_send_options(transport) == [
               routing_headers: [%{header: "Zone", path: ["region"], type: "string"}]
             ]

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => retry["id"],
        "result" => %{"content" => []}
      })

      assert {:ok, %{"content" => []}} = Task.await(call_task)
    end

    test "schema refresh stops when a server repeats a cursor" do
      {client, transport} = start_client()
      do_connect(client, transport)

      call_task = Task.async(fn -> Client.call_tool(client, "weather", %{"region" => "east"}) end)
      first_call = last_after_connect(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => first_call["id"],
        "error" => %{
          "code" => -32_020,
          "message" => "Header mismatch",
          "data" => "missing mcp-param-region header"
        }
      })

      first_page = last_after_connect(transport, 2)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => first_page["id"],
        "result" => %{"tools" => [], "nextCursor" => "same"}
      })

      second_page = last_after_connect(transport, 3)
      assert second_page["params"]["cursor"] == "same"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => second_page["id"],
        "result" => %{"tools" => [], "nextCursor" => "same"}
      })

      assert {:error, error} = Task.await(call_task)
      assert error.code == -32_020
      assert length(MockTransport.sent_messages(transport)) == 4
      assert Client.status(client) == :ready
    end

    test "transport send errors are returned immediately without pending timeout state" do
      {client, _transport} = start_client(transport: {MockTransport, send_error: :invalid_route})

      assert Client.call_tool(client, "weather", %{}, timeout: 100) ==
               {:error, :invalid_route}
    end

    test "call_tool surfaces an error response" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.call_tool(client, "bad", %{}) end)
      req = last_after_connect(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "error" => %{"code" => -32_601, "message" => "Method not found"}
      })

      {:error, error} = Task.await(task)
      assert error.code == -32_601
    end

    test "read_resource sends the uri" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.read_resource(client, "file:///t.txt") end)
      req = last_after_connect(transport, 1)
      assert req["method"] == "resources/read"
      assert req["params"]["uri"] == "file:///t.txt"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "result" => %{"contents" => [%{"uri" => "file:///t.txt", "text" => "hello"}]}
      })

      {:ok, result} = Task.await(task)
      assert hd(result["contents"])["text"] == "hello"
    end

    test "get_prompt sends name and arguments" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.get_prompt(client, "greeting", %{"name" => "World"}) end)
      req = last_after_connect(transport, 1)
      assert req["method"] == "prompts/get"
      assert req["params"]["arguments"] == %{"name" => "World"}

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "result" => %{
          "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "Hi"}}]
        }
      })

      {:ok, result} = Task.await(task)
      assert length(result["messages"]) == 1
    end
  end

  describe "MRTR client retry" do
    test "an input_required result is transparently completed via :on_input_required" do
      {client, transport} =
        start_client(on_input_required: fn _requests -> %{"name" => %{"name" => "Ada"}} end)

      do_connect(client, transport)

      task = Task.async(fn -> Client.call_tool(client, "needs_input", %{}) end)
      first = last_after_connect(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => first["id"],
        "result" => %{
          "resultType" => "input_required",
          "inputRequests" => %{
            "name" => %{"method" => "elicitation/create", "params" => %{}}
          },
          "requestState" => "rs-1"
        }
      })

      # The client auto-retries carrying requestState + inputResponses.
      retry = last_after_connect(transport, 2)
      assert retry["method"] == "tools/call"
      assert retry["params"]["requestState"] == "rs-1"
      assert retry["params"]["inputResponses"] == %{"name" => %{"name" => "Ada"}}

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => retry["id"],
        "result" => %{
          "resultType" => "complete",
          "content" => [%{"type" => "text", "text" => "hi Ada"}]
        }
      })

      {:ok, result} = Task.await(task)
      assert hd(result["content"])["text"] == "hi Ada"
    end

    test "an ephemeral retry omits requestState instead of serializing null" do
      {client, transport} =
        start_client(on_input_required: fn _requests -> %{"answer" => %{"value" => "yes"}} end)

      do_connect(client, transport)
      task = Task.async(fn -> Client.call_tool(client, "ephemeral", %{}) end)
      first = last_after_connect(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => first["id"],
        "result" => %{
          "resultType" => "input_required",
          "inputRequests" => %{"answer" => %{"method" => "elicitation/create", "params" => %{}}}
        }
      })

      retry = last_after_connect(transport, 2)
      refute Map.has_key?(retry["params"], "requestState")
      assert retry["params"]["inputResponses"] == %{"answer" => %{"value" => "yes"}}

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => retry["id"],
        "result" => %{"resultType" => "complete", "content" => []}
      })

      assert {:ok, %{"resultType" => "complete"}} = Task.await(task)
    end

    test "input-required retry is universal for prompts/get" do
      {client, transport} =
        start_client(on_input_required: fn _requests -> %{"context" => %{"value" => "ready"}} end)

      do_connect(client, transport)
      task = Task.async(fn -> Client.get_prompt(client, "needs_input", %{}) end)
      first = last_after_connect(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => first["id"],
        "result" => %{
          "resultType" => "input_required",
          "inputRequests" => %{"context" => %{"method" => "elicitation/create", "params" => %{}}}
        }
      })

      retry = last_after_connect(transport, 2)
      assert retry["method"] == "prompts/get"
      assert retry["params"]["name"] == "needs_input"
      assert retry["params"]["inputResponses"] == %{"context" => %{"value" => "ready"}}

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => retry["id"],
        "result" => %{
          "resultType" => "complete",
          "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "ok"}}]
        }
      })

      assert {:ok, %{"resultType" => "complete"}} = Task.await(task)
    end

    test "without a resolver the input_required result is returned as-is" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.call_tool(client, "needs_input", %{}) end)
      req = last_after_connect(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "result" => %{"resultType" => "input_required", "requestState" => "rs-1"}
      })

      {:ok, result} = Task.await(task)
      assert result["resultType"] == "input_required"
    end
  end

  describe "notifications" do
    test "dispatches to a pid handler" do
      {client, transport} = start_client(notification_handler: self())
      do_connect(client, transport)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/tools/list_changed"
      })

      assert_receive {:mcp_notification, "notifications/tools/list_changed", nil}, 1000
    end

    test "dispatches to a function handler" do
      test_pid = self()
      handler = fn method, params -> send(test_pid, {:notif, method, params}) end
      {client, transport} = start_client(notification_handler: handler)
      do_connect(client, transport)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/message",
        "params" => %{"level" => "info", "data" => "hello"}
      })

      assert_receive {:notif, "notifications/message", %{"level" => "info"}}, 1000
    end
  end

  describe "lifecycle" do
    test "close is idempotent" do
      {client, _transport} = start_client()
      assert :ok = Client.close(client)
      assert :ok = Client.close(client)
    end

    test "times out a pending request" do
      {client, transport} = start_client(request_timeout: 50)
      do_connect(client, transport)
      assert {:error, :timeout} = Client.list_tools(client, timeout: 200)
    end

    test "notifies pending requests when the transport closes" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_tools(client) end)
      wait_for_sent(transport, 2)
      send(client, {:mcp_transport_closed, :normal})

      assert {:error, {:transport_closed, :normal}} = Task.await(task)
      assert Client.status(client) == :closed
    end
  end

  describe "cancel/3" do
    test "sends a cancellation notification" do
      {client, transport} = start_client()
      do_connect(client, transport)

      Client.cancel(client, 42, "no longer needed")
      notification = last_after_connect(transport, 1)
      assert notification["method"] == "notifications/cancelled"
      assert notification["params"]["requestId"] == 42
      refute Map.has_key?(notification, "id")
    end
  end

  describe "pagination" do
    test "list_all_tools paginates through pages" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_all_tools(client) end)
      req1 = last_after_connect(transport, 1)
      refute req1["params"]["cursor"]

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req1["id"],
        "result" => %{
          "tools" => [%{"name" => "t1", "inputSchema" => %{"type" => "object"}}],
          "nextCursor" => "c1"
        }
      })

      req2 = last_after_connect(transport, 2)
      assert req2["params"]["cursor"] == "c1"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => req2["id"],
        "result" => %{
          "tools" => [%{"name" => "t2", "inputSchema" => %{"type" => "object"}}]
        }
      })

      {:ok, tools} = Task.await(task)
      assert length(tools) == 2
    end
  end

  describe "server_capabilities/1 and server_info/1" do
    test "returns discovered capabilities and info" do
      {client, transport} = start_client()
      do_connect(client, transport)

      assert Client.server_capabilities(client).tools != nil
      assert Client.server_info(client).name == "test-server"
    end
  end

  describe "concurrent requests" do
    test "handles multiple concurrent requests" do
      {client, transport} = start_client()
      do_connect(client, transport)

      t1 = Task.async(fn -> Client.list_tools(client) end)
      t2 = Task.async(fn -> Client.list_resources(client) end)

      messages = wait_for_sent(transport, 3)

      messages
      |> Enum.filter(&(Map.has_key?(&1, "id") && &1["method"] != "server/discover"))
      |> Enum.each(fn req ->
        result =
          if req["method"] == "tools/list", do: %{"tools" => []}, else: %{"resources" => []}

        MockTransport.inject(transport, %{
          "jsonrpc" => "2.0",
          "id" => req["id"],
          "result" => result
        })
      end)

      assert {:ok, _} = Task.await(t1)
      assert {:ok, _} = Task.await(t2)
    end
  end
end
