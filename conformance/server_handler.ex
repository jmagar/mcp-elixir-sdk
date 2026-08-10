defmodule MCP.Conformance.ServerHandler do
  @moduledoc """
  Handler module implementing all MCP conformance test tools, resources, and prompts.

  Uses `handle_call_tool/4` (with ToolContext) to support sending notifications
  and making server-to-client requests during tool execution.
  """

  @behaviour MCP.Server.Handler

  alias MCP.Server.ToolContext
  alias MCP.Server.SubscriptionPublisher

  @test_image_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
  @test_audio_base64 "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQIAAAA="

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_set_log_level(_level, _ctx, _config), do: :ok

  @impl true
  def handle_subscribe(_uri, _ctx, _config), do: :ok

  @impl true
  def handle_unsubscribe(_uri, _ctx, _config), do: :ok

  # --- Tools ---

  @impl true
  def handle_list_tools(_cursor, _ctx, _config) do
    tools = [
      %{
        "name" => "test_simple_text",
        "description" => "Tests simple text content response",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_image_content",
        "description" => "Tests image content response",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_audio_content",
        "description" => "Tests audio content response",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_multiple_content_types",
        "description" => "Tests multiple content types in response",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_embedded_resource",
        "description" => "Tests embedded resource content",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_tool_with_logging",
        "description" => "Tests tool that emits log messages",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_tool_with_progress",
        "description" => "Tests tool with progress notifications",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_error_handling",
        "description" => "Tests error handling",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_sampling",
        "description" => "Tests sampling via server-initiated request",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"prompt" => %{"type" => "string"}},
          "required" => ["prompt"]
        }
      },
      %{
        "name" => "test_elicitation",
        "description" => "Tests elicitation via server-initiated request",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"message" => %{"type" => "string"}},
          "required" => ["message"]
        }
      },
      %{
        "name" => "test_elicitation_sep1034_defaults",
        "description" => "Tests elicitation with default values",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_elicitation_sep1330_enums",
        "description" => "Tests elicitation with enum schemas",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "json_schema_2020_12_tool",
        "description" => "Tool with JSON Schema 2020-12 features",
        "inputSchema" => json_schema_2020_12()
      },
      %{
        "name" => "test_missing_capability",
        "description" => "Requires the sampling client capability",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_streaming_elicitation",
        "description" => "Exercises MRTR on a response stream",
        "inputSchema" => %{"type" => "object"}
      },
      input_required_tool("test_input_required_result_elicitation"),
      input_required_tool("test_input_required_result_sampling"),
      input_required_tool("test_input_required_result_list_roots"),
      input_required_tool("test_input_required_result_request_state"),
      input_required_tool("test_input_required_result_multiple_inputs"),
      input_required_tool("test_input_required_result_multi_round"),
      input_required_tool("test_input_required_result_capabilities"),
      input_required_tool("test_input_required_result_tampered_state"),
      %{
        "name" => "test_logging_tool",
        "description" => "Does not log unless a request logLevel permits it",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_trigger_tool_change",
        "description" => "Triggers a tools list-changed notification",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_trigger_prompt_change",
        "description" => "Triggers a prompts list-changed notification",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "test_custom_headers",
        "description" => "Exercises x-mcp-header validation",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "region" => %{"type" => "string", "x-mcp-header" => "Region"},
            "priority" => %{"type" => "integer", "x-mcp-header" => "Priority"},
            "query" => %{"type" => "string"}
          },
          "required" => ["region", "priority", "query"]
        }
      }
    ]

    {:ok, tools, nil}
  end

  @impl true
  def handle_call_tool("test_simple_text", _args, _ctx, _config) do
    {:ok, [%{"type" => "text", "text" => "This is a simple text response for testing."}]}
  end

  def handle_call_tool("test_image_content", _args, _ctx, _config) do
    {:ok, [%{"type" => "image", "data" => @test_image_base64, "mimeType" => "image/png"}]}
  end

  def handle_call_tool("test_audio_content", _args, _ctx, _config) do
    {:ok, [%{"type" => "audio", "data" => @test_audio_base64, "mimeType" => "audio/wav"}]}
  end

  def handle_call_tool("test_multiple_content_types", _args, _ctx, _config) do
    content = [
      %{"type" => "text", "text" => "Multiple content types test:"},
      %{"type" => "image", "data" => @test_image_base64, "mimeType" => "image/png"},
      %{
        "type" => "resource",
        "resource" => %{
          "uri" => "test://mixed-content-resource",
          "mimeType" => "application/json",
          "text" => Jason.encode!(%{"test" => "data", "value" => 123})
        }
      }
    ]

    {:ok, content}
  end

  def handle_call_tool("test_embedded_resource", _args, _ctx, _config) do
    content = [
      %{
        "type" => "resource",
        "resource" => %{
          "uri" => "test://embedded-resource",
          "mimeType" => "text/plain",
          "text" => "This is an embedded resource content."
        }
      }
    ]

    {:ok, content}
  end

  def handle_call_tool("test_tool_with_logging", _args, ctx, _config) do
    ToolContext.log(ctx, "info", "Tool execution started")
    Process.sleep(50)
    ToolContext.log(ctx, "info", "Tool processing data")
    Process.sleep(50)
    ToolContext.log(ctx, "info", "Tool execution completed")

    {:ok, [%{"type" => "text", "text" => "Tool with logging executed successfully"}]}
  end

  def handle_call_tool("test_tool_with_progress", _args, ctx, _config) do
    ToolContext.send_progress(ctx, 0, 100)
    Process.sleep(50)
    ToolContext.send_progress(ctx, 50, 100)
    Process.sleep(50)
    ToolContext.send_progress(ctx, 100, 100)

    {:ok, [%{"type" => "text", "text" => "progress-token"}]}
  end

  def handle_call_tool("test_error_handling", _args, _ctx, _config) do
    {:ok, [%{"type" => "text", "text" => "This tool intentionally returns an error for testing"}],
     true}
  end

  def handle_call_tool("json_schema_2020_12_tool", _args, _ctx, _config) do
    {:ok, [%{"type" => "text", "text" => "schema preserved"}]}
  end

  def handle_call_tool("test_missing_capability", _args, _ctx, _config) do
    {:error, -32_021, "Missing required client capability: sampling",
     %{"requiredCapabilities" => %{"sampling" => %{}}}}
  end

  def handle_call_tool("test_streaming_elicitation", _args, %{input: nil}, _config) do
    {:input_required,
     %{
       "elicitation" => %{
         "method" => "elicitation/create",
         "params" => %{
           "mode" => "form",
           "message" => "Provide a value",
           "requestedSchema" => %{"type" => "object", "properties" => %{}}
         }
       }
     }, "streaming-elicitation"}
  end

  def handle_call_tool("test_streaming_elicitation", _args, %{input: %{responses: _}}, _config) do
    {:ok, [%{"type" => "text", "text" => "complete"}]}
  end

  def handle_call_tool("test_input_required_result_elicitation", _args, %{input: nil}, _config) do
    {:input_required, %{"user_name" => elicitation_request("Provide your name")}, nil}
  end

  def handle_call_tool(
        "test_input_required_result_elicitation",
        _args,
        %{input: %{responses: %{"user_name" => response}}},
        _config
      )
      when is_map(response) do
    complete_text("elicitation-complete")
  end

  def handle_call_tool("test_input_required_result_elicitation", _args, _ctx, _config) do
    {:input_required, %{"user_name" => elicitation_request("Provide your name")}, nil}
  end

  def handle_call_tool("test_input_required_result_sampling", _args, %{input: nil}, _config) do
    {:input_required, %{"capital_question" => sampling_request()}, nil}
  end

  def handle_call_tool(
        "test_input_required_result_sampling",
        _args,
        %{input: %{responses: %{"capital_question" => response}}},
        _config
      )
      when is_map(response) do
    complete_text("sampling-complete")
  end

  def handle_call_tool("test_input_required_result_sampling", _args, _ctx, _config) do
    {:input_required, %{"capital_question" => sampling_request()}, nil}
  end

  def handle_call_tool("test_input_required_result_list_roots", _args, %{input: nil}, _config) do
    {:input_required, %{"client_roots" => roots_request()}, nil}
  end

  def handle_call_tool(
        "test_input_required_result_list_roots",
        _args,
        %{input: %{responses: %{"client_roots" => response}}},
        _config
      )
      when is_map(response) do
    complete_text("roots-complete")
  end

  def handle_call_tool("test_input_required_result_list_roots", _args, _ctx, _config) do
    {:input_required, %{"client_roots" => roots_request()}, nil}
  end

  def handle_call_tool("test_input_required_result_request_state", _args, %{input: nil}, _config) do
    {:input_required, %{"confirm" => elicitation_request("Confirm")}, "state-ok"}
  end

  def handle_call_tool(
        "test_input_required_result_request_state",
        _args,
        %{input: %{request_state: "state-ok", responses: %{"confirm" => response}}},
        _config
      )
      when is_map(response) do
    complete_text("state-ok")
  end

  def handle_call_tool("test_input_required_result_request_state", _args, %{input: %{}}, _config) do
    {:error, -32_602, "Invalid requestState"}
  end

  def handle_call_tool("test_input_required_result_tampered_state", _args, %{input: nil}, _config) do
    {:input_required, %{"confirm" => elicitation_request("Confirm")}, "signed-state-v1"}
  end

  def handle_call_tool(
        "test_input_required_result_tampered_state",
        _args,
        %{input: %{request_state: "signed-state-v1", responses: %{"confirm" => response}}},
        _config
      )
      when is_map(response) do
    complete_text("tamper-check-complete")
  end

  def handle_call_tool("test_input_required_result_tampered_state", _args, %{input: %{}}, _config) do
    {:error, -32_602, "Invalid requestState integrity check"}
  end

  def handle_call_tool(
        "test_input_required_result_multiple_inputs",
        _args,
        %{input: nil},
        _config
      ) do
    requests = %{
      "elicitation" => elicitation_request("Provide context"),
      "sampling" => sampling_request(),
      "roots" => roots_request()
    }

    {:input_required, requests, "multiple-inputs-state"}
  end

  def handle_call_tool(
        "test_input_required_result_multiple_inputs",
        _args,
        %{
          input: %{
            request_state: "multiple-inputs-state",
            responses: %{"elicitation" => e, "sampling" => s, "roots" => r}
          }
        },
        _config
      )
      when is_map(e) and is_map(s) and is_map(r) do
    complete_text("multiple-inputs-complete")
  end

  def handle_call_tool(
        "test_input_required_result_multiple_inputs",
        _args,
        %{input: %{}},
        _config
      ) do
    {:error, -32_602, "Invalid multiple-input continuation"}
  end

  def handle_call_tool("test_input_required_result_multi_round", _args, %{input: nil}, _config) do
    {:input_required, %{"step1" => elicitation_request("First step")}, "state-round-1"}
  end

  def handle_call_tool(
        "test_input_required_result_multi_round",
        _args,
        %{input: %{request_state: "state-round-1", responses: %{"step1" => response}}},
        _config
      )
      when is_map(response) do
    {:input_required, %{"step2" => sampling_request()}, "state-round-2"}
  end

  def handle_call_tool(
        "test_input_required_result_multi_round",
        _args,
        %{input: %{request_state: "state-round-2", responses: %{"step2" => response}}},
        _config
      )
      when is_map(response) do
    complete_text("multi-round-complete")
  end

  def handle_call_tool("test_input_required_result_multi_round", _args, %{input: %{}}, _config) do
    {:error, -32_602, "Invalid multi-round continuation"}
  end

  def handle_call_tool(
        "test_input_required_result_capabilities",
        _args,
        %{input: nil, meta: meta},
        _config
      ) do
    capabilities = Map.get(meta || %{}, "io.modelcontextprotocol/clientCapabilities", %{})
    requests = capability_input_requests(capabilities)
    {:input_required, requests, nil}
  end

  def handle_call_tool(
        "test_input_required_result_capabilities",
        _args,
        %{input: %{responses: responses}},
        _config
      )
      when is_map(responses) do
    complete_text("capability-inputs-complete")
  end

  def handle_call_tool("test_logging_tool", _args, _ctx, _config) do
    {:ok, [%{"type" => "text", "text" => "no log level, no logs"}]}
  end

  def handle_call_tool("test_trigger_tool_change", _args, _ctx, _config) do
    :ok =
      SubscriptionPublisher.publish(
        MCP.Conformance.SubscriptionRegistry,
        __MODULE__,
        "notifications/tools/list_changed",
        %{}
      )

    {:ok, [%{"type" => "text", "text" => "tool list changed"}]}
  end

  def handle_call_tool("test_trigger_prompt_change", _args, _ctx, _config) do
    :ok =
      SubscriptionPublisher.publish(
        MCP.Conformance.SubscriptionRegistry,
        __MODULE__,
        "notifications/prompts/list_changed",
        %{}
      )

    {:ok, [%{"type" => "text", "text" => "prompt list changed"}]}
  end

  def handle_call_tool("test_custom_headers", _args, _ctx, _config) do
    {:ok, [%{"type" => "text", "text" => "custom headers accepted"}]}
  end

  def handle_call_tool("test_sampling", args, %{input: nil}, _config) do
    request = %{
      "method" => "sampling/createMessage",
      "params" => %{
        "messages" => [
          %{
            "role" => "user",
            "content" => %{"type" => "text", "text" => Map.get(args, "prompt", "")}
          }
        ],
        "maxTokens" => 100
      }
    }

    {:input_required, %{"sampling" => request}, "sampling-state"}
  end

  def handle_call_tool("test_sampling", _args, %{input: %{responses: responses}}, _config) do
    {:ok, [%{"type" => "text", "text" => "LLM response: #{inspect(responses["sampling"])}"}]}
  end

  def handle_call_tool("test_elicitation_sep1034_defaults", _args, %{input: nil}, _config) do
    request = %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Provide values with defaults",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "default" => "John Doe"},
            "age" => %{"type" => "integer", "default" => 30},
            "score" => %{"type" => "number", "default" => 95.5},
            "status" => %{
              "type" => "string",
              "enum" => ["active", "inactive", "pending"],
              "default" => "active"
            },
            "verified" => %{"type" => "boolean", "default" => true}
          }
        }
      }
    }

    {:input_required, %{"elicitation" => request}, "elicitation-defaults-state"}
  end

  def handle_call_tool("test_elicitation_sep1330_enums", _args, %{input: nil}, _config) do
    choices = [
      %{"const" => "value1", "title" => "First Option"},
      %{"const" => "value2", "title" => "Second Option"}
    ]

    request = %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Choose enum values",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{
            "untitledSingle" => %{
              "type" => "string",
              "enum" => ["option1", "option2", "option3"]
            },
            "titledSingle" => %{"type" => "string", "oneOf" => choices},
            "legacyEnum" => %{
              "type" => "string",
              "enum" => ["opt1", "opt2", "opt3"],
              "enumNames" => ["Option One", "Option Two", "Option Three"]
            },
            "untitledMulti" => %{
              "type" => "array",
              "items" => %{
                "type" => "string",
                "enum" => ["option1", "option2", "option3"]
              }
            },
            "titledMulti" => %{"type" => "array", "items" => %{"anyOf" => choices}}
          }
        }
      }
    }

    {:input_required, %{"elicitation" => request}, "elicitation-enums-state"}
  end

  def handle_call_tool(name, args, %{input: nil}, _config)
      when name in [
             "test_elicitation",
             "test_elicitation_sep1034_defaults",
             "test_elicitation_sep1330_enums"
           ] do
    request = %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => Map.get(args, "message", "Please provide input"),
        "requestedSchema" => %{"type" => "object", "properties" => %{}}
      }
    }

    {:input_required, %{"elicitation" => request}, "elicitation-state"}
  end

  def handle_call_tool(name, _args, %{input: %{responses: responses}}, _config)
      when name in [
             "test_elicitation",
             "test_elicitation_sep1034_defaults",
             "test_elicitation_sep1330_enums"
           ] do
    {:ok, [%{"type" => "text", "text" => "User response: #{inspect(responses["elicitation"])}"}]}
  end

  def handle_call_tool(name, _args, _ctx, _config) do
    {:error, -32_601, "Unknown tool: #{name}"}
  end

  # --- Resources ---

  @impl true
  def handle_list_resources(_cursor, _ctx, _config) do
    resources = [
      %{
        "uri" => "test://static-text",
        "name" => "Static Text Resource",
        "mimeType" => "text/plain"
      },
      %{
        "uri" => "test://static-binary",
        "name" => "Static Binary Resource",
        "mimeType" => "image/png"
      },
      %{
        "uri" => "test://watched-resource",
        "name" => "Watched Resource",
        "mimeType" => "text/plain"
      }
    ]

    {:ok, resources, nil}
  end

  @impl true
  def handle_read_resource("test://static-text", _ctx, _config) do
    {:ok,
     [
       %{
         "uri" => "test://static-text",
         "mimeType" => "text/plain",
         "text" => "This is the content of the static text resource."
       }
     ]}
  end

  def handle_read_resource("test://static-binary", _ctx, _config) do
    {:ok,
     [
       %{
         "uri" => "test://static-binary",
         "mimeType" => "image/png",
         "blob" => @test_image_base64
       }
     ]}
  end

  def handle_read_resource("test://watched-resource", _ctx, _config) do
    {:ok,
     [
       %{
         "uri" => "test://watched-resource",
         "mimeType" => "text/plain",
         "text" => "Watched resource content"
       }
     ]}
  end

  def handle_read_resource("test://template/" <> rest, _ctx, _config) do
    id = rest |> String.split("/") |> hd()

    {:ok,
     [
       %{
         "uri" => "test://template/#{id}/data",
         "mimeType" => "application/json",
         "text" =>
           Jason.encode!(%{"id" => id, "templateTest" => true, "data" => "Data for ID: #{id}"})
       }
     ]}
  end

  def handle_read_resource(uri, _ctx, _config) do
    {:error, -32_602, "Resource not found: #{uri}", %{"uri" => uri}}
  end

  @impl true
  def handle_list_resource_templates(_cursor, _ctx, _config) do
    templates = [
      %{
        "uriTemplate" => "test://template/{id}/data",
        "name" => "Template Resource",
        "description" => "A resource template with ID parameter",
        "mimeType" => "application/json"
      }
    ]

    {:ok, templates, nil}
  end

  # --- Prompts ---

  @impl true
  def handle_list_prompts(_cursor, _ctx, _config) do
    prompts = [
      %{
        "name" => "test_simple_prompt",
        "description" => "Simple prompt without arguments"
      },
      %{
        "name" => "test_prompt_with_arguments",
        "description" => "Prompt with arguments",
        "arguments" => [
          %{
            "name" => "arg1",
            "description" => "First test argument",
            "required" => true
          },
          %{
            "name" => "arg2",
            "description" => "Second test argument",
            "required" => true
          }
        ]
      },
      %{
        "name" => "test_prompt_with_embedded_resource",
        "description" => "Prompt with embedded resource",
        "arguments" => [
          %{
            "name" => "resourceUri",
            "description" => "URI of the resource to embed",
            "required" => true
          }
        ]
      },
      %{
        "name" => "test_prompt_with_image",
        "description" => "Prompt with image content"
      },
      %{
        "name" => "test_input_required_result_prompt",
        "description" => "Prompt that exercises universal MRTR"
      }
    ]

    {:ok, prompts, nil}
  end

  @impl true
  def handle_get_prompt("test_simple_prompt", _args, _ctx, _config) do
    {:ok,
     %{
       "messages" => [
         %{
           "role" => "user",
           "content" => %{
             "type" => "text",
             "text" => "This is a simple prompt for testing."
           }
         }
       ]
     }}
  end

  def handle_get_prompt("test_prompt_with_arguments", args, _ctx, _config) do
    arg1 = Map.get(args || %{}, "arg1", "")
    arg2 = Map.get(args || %{}, "arg2", "")

    {:ok,
     %{
       "messages" => [
         %{
           "role" => "user",
           "content" => %{
             "type" => "text",
             "text" => "Prompt with arguments: arg1='#{arg1}', arg2='#{arg2}'"
           }
         }
       ]
     }}
  end

  def handle_get_prompt("test_prompt_with_embedded_resource", args, _ctx, _config) do
    uri = Map.get(args || %{}, "resourceUri", "test://example-resource")

    {:ok,
     %{
       "messages" => [
         %{
           "role" => "user",
           "content" => %{
             "type" => "resource",
             "resource" => %{
               "uri" => uri,
               "mimeType" => "text/plain",
               "text" => "Embedded resource content for testing."
             }
           }
         },
         %{
           "role" => "user",
           "content" => %{
             "type" => "text",
             "text" => "Please process the embedded resource above."
           }
         }
       ]
     }}
  end

  def handle_get_prompt("test_prompt_with_image", _args, _ctx, _config) do
    {:ok,
     %{
       "messages" => [
         %{
           "role" => "user",
           "content" => %{
             "type" => "image",
             "data" => @test_image_base64,
             "mimeType" => "image/png"
           }
         },
         %{
           "role" => "user",
           "content" => %{
             "type" => "text",
             "text" => "Please analyze the image above."
           }
         }
       ]
     }}
  end

  def handle_get_prompt("test_input_required_result_prompt", _args, %{input: nil}, _config) do
    {:input_required, %{"user_context" => elicitation_request("Provide prompt context")}, nil}
  end

  def handle_get_prompt(
        "test_input_required_result_prompt",
        _args,
        %{input: %{responses: %{"user_context" => response}}},
        _config
      )
      when is_map(response) do
    {:ok,
     %{
       "messages" => [
         %{
           "role" => "user",
           "content" => %{"type" => "text", "text" => "prompt-input-complete"}
         }
       ]
     }}
  end

  def handle_get_prompt("test_input_required_result_prompt", _args, _ctx, _config) do
    {:input_required, %{"user_context" => elicitation_request("Provide prompt context")}, nil}
  end

  def handle_get_prompt(name, _args, _ctx, _config) do
    {:error, -32_601, "Unknown prompt: #{name}"}
  end

  # --- Completion ---

  @impl true
  def handle_complete(_ref, _argument, _ctx, _config) do
    {:ok, %{"values" => [], "total" => 0, "hasMore" => false}}
  end

  @impl true
  def handle_listen_subscriptions(requested, _ctx, _config), do: {:ok, requested}

  defp input_required_tool(name) do
    %{
      "name" => name,
      "description" => "Exercises an InputRequiredResult conformance path",
      "inputSchema" => %{"type" => "object"}
    }
  end

  defp elicitation_request(message) do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "mode" => "form",
        "message" => message,
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "string"}}
        }
      }
    }
  end

  defp sampling_request do
    %{
      "method" => "sampling/createMessage",
      "params" => %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "Capital of France?"}}
        ],
        "maxTokens" => 100
      }
    }
  end

  defp roots_request, do: %{"method" => "roots/list", "params" => %{}}

  defp capability_input_requests(capabilities) do
    %{}
    |> maybe_put_request("sampling", Map.has_key?(capabilities, "sampling"), sampling_request())
    |> maybe_put_request(
      "elicitation",
      Map.has_key?(capabilities, "elicitation"),
      elicitation_request("Provide context")
    )
    |> maybe_put_request("roots", Map.has_key?(capabilities, "roots"), roots_request())
  end

  defp maybe_put_request(requests, _key, false, _request), do: requests
  defp maybe_put_request(requests, key, true, request), do: Map.put(requests, key, request)

  defp complete_text(text), do: {:ok, [%{"type" => "text", "text" => text}]}

  defp json_schema_2020_12 do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "$defs" => %{
        "address" => %{
          "$anchor" => "addressDef",
          "type" => "object",
          "properties" => %{
            "street" => %{"type" => "string"},
            "city" => %{"type" => "string"}
          }
        }
      },
      "properties" => %{
        "name" => %{"type" => "string"},
        "address" => %{"$ref" => "#/$defs/address"},
        "contactMethod" => %{"type" => "string", "enum" => ["phone", "email"]},
        "phone" => %{"type" => "string"},
        "email" => %{"type" => "string"}
      },
      "allOf" => [%{"anyOf" => [%{"required" => ["phone"]}, %{"required" => ["email"]}]}],
      "if" => %{
        "properties" => %{"contactMethod" => %{"const" => "phone"}},
        "required" => ["contactMethod"]
      },
      "then" => %{"required" => ["phone"]},
      "else" => %{"required" => ["email"]},
      "additionalProperties" => false
    }
  end
end
