defmodule MCP.Test.StatelessHandler do
  @moduledoc """
  Test handler implementing the 2026-07-28 **context-bearing** callbacks for all
  eight identity-capable families, used to drive `MCP.Server.Dispatch`
  in-process. Every callback reads caller identity from `ctx.identity` — never
  from arguments — and echoes it into its result so the dispatch's MC-1 (context
  reaches every callback) and MC-4 (no model-arg override) guarantees can be
  asserted per family.
  """
  @behaviour MCP.Server.Handler

  alias MCP.Protocol.Messages.Tools.CallResult
  alias MCP.Protocol.Types.SubscriptionFilter
  alias MCP.Server.ToolContext

  @impl true
  def init(opts), do: {:ok, %{tools: Keyword.get(opts, :tools, [])}}

  @impl true
  def handle_list_tools(_cursor, %ToolContext{} = ctx, _config) do
    {:ok, [%{"name" => "whoami", "boundIdentity" => id_str(ctx)}], nil}
  end

  @impl true
  def handle_call_tool("whoami", _args, %ToolContext{} = ctx, _config) do
    {:ok, [%{"type" => "text", "text" => id_str(ctx)}]}
  end

  # MRTR (SEP-2322): on a first attempt (`ctx.input` nil) the tool asks for
  # client input and hands back a continuation token; on the retry it reads the
  # fulfilled responses from `ctx.input` and completes.
  def handle_call_tool("needs_input", _args, %ToolContext{input: nil}, _config) do
    input_requests = %{"name" => %{"method" => "elicitation/create", "params" => %{}}}
    {:input_required, input_requests, "rs-token-1"}
  end

  def handle_call_tool(
        "needs_input",
        _args,
        %ToolContext{input: %{responses: responses}},
        _config
      ) do
    name = get_in(responses || %{}, ["name", "name"]) || "?"
    {:ok, [%{"type" => "text", "text" => "hello #{name}"}]}
  end

  # Reads identity ONLY from ctx; the model-supplied "identity" arg is ignored.
  def handle_call_tool("whoami_with_arg", _args, %ToolContext{} = ctx, _config) do
    {:ok, [%{"type" => "text", "text" => id_str(ctx)}]}
  end

  # A tool that never touches identity — used to prove the SDK response
  # envelope carries no identity of its own (§3.2 identity-never-on-the-wire).
  def handle_call_tool("silent", _args, %ToolContext{}, _config) do
    {:ok, [%{"type" => "text", "text" => "ok"}]}
  end

  def handle_call_tool("structured", _args, %ToolContext{}, _config) do
    {:ok,
     %CallResult{
       content: [],
       structured_content: false,
       is_error: false,
       extra: %{"vendorResult" => nil}
     }}
  end

  def handle_call_tool("throwing", _args, %ToolContext{}, _config), do: throw(:handler_failure)
  def handle_call_tool("exiting", _args, %ToolContext{}, _config), do: exit(:handler_failure)
  def handle_call_tool("invalid_return", _args, %ToolContext{}, _config), do: :invalid

  # MRTR identity variant: like `needs_input`, but the completion echoes
  # `ctx.identity` (re-resolved from THIS request's pipeline on the retry),
  # never anything carried in the model-supplied requestState/inputResponses.
  def handle_call_tool("needs_input_id", _args, %ToolContext{input: nil}, _config) do
    input_requests = %{"identity" => %{"method" => "elicitation/create", "params" => %{}}}
    {:input_required, input_requests, "rs-token-id"}
  end

  def handle_call_tool(
        "needs_input_id",
        _args,
        %ToolContext{input: %{responses: _}} = ctx,
        _config
      ) do
    {:ok, [%{"type" => "text", "text" => id_str(ctx)}]}
  end

  # Ruling 7 regression (MES-14): emit an identity-bearing notification, then
  # RAISE. Proves a prior request's per-request notification collector is
  # unreachable to the next same-process request even when the handler crashes,
  # so no residue leaks into another principal's response.
  def handle_call_tool("emit_then_raise", _args, %ToolContext{} = ctx, _state) do
    ToolContext.log(ctx, "info", %{"identity" => id_str(ctx)})
    raise "boom after emitting a notification"
  end

  def handle_call_tool(_name, _args, %ToolContext{}, _config) do
    {:error, -32_602, "unknown tool"}
  end

  @impl true
  def handle_list_resources(_cursor, %ToolContext{} = ctx, _config) do
    {:ok, [%{"uri" => "mem://res", "name" => id_str(ctx)}], nil}
  end

  @impl true
  def handle_read_resource("mem://missing" = uri, %ToolContext{}, _config) do
    {:error, -32_602, "resource not found", %{"uri" => uri}}
  end

  def handle_read_resource("mem://needs-input", %ToolContext{input: nil}, _config) do
    request = %{"method" => "elicitation/create", "params" => %{}}
    {:input_required, %{"resource_input" => request}, "resource-state-1"}
  end

  def handle_read_resource(
        "mem://needs-input" = uri,
        %ToolContext{
          input: %{request_state: "resource-state-1", responses: %{"resource_input" => response}}
        },
        _config
      )
      when is_map(response) do
    {:ok, [%{"uri" => uri, "text" => Map.get(response, "value", "?")}]}
  end

  def handle_read_resource("mem://needs-input", %ToolContext{input: %{}}, _config) do
    {:error, -32_602, "invalid resource continuation"}
  end

  def handle_read_resource(uri, %ToolContext{} = ctx, _config) do
    {:ok, [%{"uri" => uri, "text" => id_str(ctx)}]}
  end

  @impl true
  def handle_list_resource_templates(_cursor, %ToolContext{} = ctx, _config) do
    {:ok, [%{"uriTemplate" => "mem://{x}", "name" => id_str(ctx)}], nil}
  end

  @impl true
  def handle_list_prompts(_cursor, %ToolContext{} = ctx, _config) do
    {:ok, [%{"name" => "who", "description" => id_str(ctx)}], nil}
  end

  # Reads identity ONLY from ctx; a model-supplied "identity" arg is ignored (AC3′).
  @impl true
  def handle_get_prompt("who", _args, %ToolContext{} = ctx, _config) do
    {:ok,
     %{
       "messages" => [
         %{"role" => "user", "content" => %{"type" => "text", "text" => id_str(ctx)}}
       ]
     }}
  end

  def handle_get_prompt("needs_input", _args, %ToolContext{input: nil}, _config) do
    request = %{"method" => "elicitation/create", "params" => %{}}
    {:input_required, %{"prompt_input" => request}, "prompt-state-1"}
  end

  def handle_get_prompt(
        "needs_input",
        _args,
        %ToolContext{input: %{request_state: "prompt-state-1", responses: responses}},
        _config
      ) do
    value = get_in(responses || %{}, ["prompt_input", "value"]) || "?"

    {:ok,
     %{
       "messages" => [
         %{"role" => "user", "content" => %{"type" => "text", "text" => value}}
       ]
     }}
  end

  def handle_get_prompt("needs_input", _args, %ToolContext{input: %{}}, _config) do
    {:error, -32_602, "invalid prompt continuation"}
  end

  @impl true
  def handle_complete(_ref, _argument, %ToolContext{} = ctx, _config) do
    {:ok, %{"values" => [id_str(ctx)], "total" => 1}}
  end

  @impl true
  def handle_listen_subscriptions(%SubscriptionFilter{} = requested, _ctx, _config),
    do: {:ok, requested}

  defp id_str(%ToolContext{identity: nil}), do: ""
  defp id_str(%ToolContext{identity: id}), do: to_string(id)
end
