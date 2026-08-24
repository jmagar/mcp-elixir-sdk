defmodule MCP.Server.Handler do
  @moduledoc """
  Behaviour for implementing MCP 2026-07-28 server handlers.

  `init/1` returns immutable launch configuration. The runtime passes that
  value to every callback and never accepts replacement configuration in a
  callback result. Consumers that need mutable state should put a supervised
  process reference in the launch configuration.

  Every request callback receives `MCP.Server.ToolContext` immediately before
  the launch configuration. All request callbacks are optional; capabilities
  are advertised only for implemented callback families.

  When configuration is built, any `init/1` failure is returned as
  `{:error, MCP.Server.Config.handler_init_error()}`. This includes ordinary
  handler errors as well as normalized raises, throws, exits, and malformed
  callback returns.
  """

  @type handler_config :: term()
  @type cursor :: String.t() | nil
  @type context :: MCP.Server.ToolContext.t()

  @doc """
  Builds immutable launch configuration once when the server configuration is
  created.

  Returned errors are wrapped by `MCP.Server.Config.build/2` in the stable
  `{:handler_init_failed, detail}` error contract.
  """
  @callback init(opts :: keyword()) :: {:ok, handler_config()} | {:error, term()}

  @callback handle_list_tools(cursor(), context(), handler_config()) ::
              {:ok, tools :: [map()], next_cursor :: cursor()}

  @callback handle_call_tool(
              name :: String.t(),
              arguments :: map(),
              context(),
              handler_config()
            ) ::
              {:ok, content :: [map()]}
              | {:ok, content :: [map()], is_error :: boolean()}
              | {:ok, result :: MCP.Protocol.Messages.Tools.CallResult.t() | map()}
              | {:input_required, requests :: %{required(String.t()) => map()},
                 request_state :: String.t() | nil}
              | {:error, code :: integer(), message :: String.t()}
              | {:error, code :: integer(), message :: String.t(), data :: term()}

  @callback handle_list_resources(cursor(), context(), handler_config()) ::
              {:ok, resources :: [map()], next_cursor :: cursor()}

  @callback handle_read_resource(String.t(), context(), handler_config()) ::
              {:ok, contents :: [map()]}
              | {:input_required, input_requests :: map(), request_state :: String.t() | nil}
              | {:error, code :: integer(), message :: String.t()}
              | {:error, code :: integer(), message :: String.t(), data :: term()}

  @callback handle_list_skills(cursor(), context(), handler_config()) ::
              {:ok, skills :: [MCP.Protocol.Types.Skill.t() | map()], next_cursor :: cursor()}
              | {:error, code :: integer(), message :: String.t()}
              | {:error, code :: integer(), message :: String.t(), data :: term()}

  @callback handle_get_skill(String.t(), context(), handler_config()) ::
              {:ok, skill :: MCP.Protocol.Types.Skill.t() | map()}
              | {:error, code :: integer(), message :: String.t()}
              | {:error, code :: integer(), message :: String.t(), data :: term()}

  @callback handle_read_resource_directory(String.t(), cursor(), context(), handler_config()) ::
              {:ok, resources :: [MCP.Protocol.Types.Resource.t() | map()],
               next_cursor :: cursor()}
              | {:error, code :: integer(), message :: String.t()}
              | {:error, code :: integer(), message :: String.t(), data :: term()}

  @callback handle_list_resource_templates(cursor(), context(), handler_config()) ::
              {:ok, templates :: [map()], next_cursor :: cursor()}

  @callback handle_list_prompts(cursor(), context(), handler_config()) ::
              {:ok, prompts :: [map()], next_cursor :: cursor()}

  @callback handle_get_prompt(String.t(), map() | nil, context(), handler_config()) ::
              {:ok, result :: map()}
              | {:error, code :: integer(), message :: String.t()}
              | {:error, code :: integer(), message :: String.t(), data :: term()}
              | {:input_required, input_requests :: map(), request_state :: String.t() | nil}

  @callback handle_complete(map(), map(), context(), handler_config()) ::
              {:ok, completion :: map()}

  @callback handle_listen_subscriptions(
              requested :: MCP.Protocol.Types.SubscriptionFilter.t(),
              context(),
              handler_config()
            ) ::
              {:ok, honored :: MCP.Protocol.Types.SubscriptionFilter.t()}
              | {:error, code :: integer(), message :: String.t()}

  @callback handle_subscribe(String.t(), context(), handler_config()) ::
              :ok
              | {:ok}
              | {:error, code :: integer(), message :: String.t()}

  @callback handle_unsubscribe(String.t(), context(), handler_config()) ::
              :ok
              | {:ok}
              | {:error, code :: integer(), message :: String.t()}

  @callback handle_set_log_level(String.t(), context(), handler_config()) ::
              :ok
              | {:ok}
              | {:error, code :: integer(), message :: String.t()}

  @optional_callbacks [
    handle_list_tools: 3,
    handle_call_tool: 4,
    handle_list_resources: 3,
    handle_read_resource: 3,
    handle_list_skills: 3,
    handle_get_skill: 3,
    handle_read_resource_directory: 4,
    handle_list_resource_templates: 3,
    handle_list_prompts: 3,
    handle_get_prompt: 4,
    handle_complete: 4,
    handle_listen_subscriptions: 3,
    handle_subscribe: 3,
    handle_unsubscribe: 3,
    handle_set_log_level: 3
  ]
end
