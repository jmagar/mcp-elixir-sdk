defmodule MCP.Protocol.Methods do
  @moduledoc """
  MCP method name constants and notification method constants.
  """

  # Request methods (client → server)
  def initialize, do: "initialize"
  def ping, do: "ping"
  # server/discover replaces the initialize handshake in the 2026-07-28 stateless core (SEP-2575)
  def discover, do: "server/discover"
  def tools_list, do: "tools/list"
  def tools_call, do: "tools/call"
  def resources_list, do: "resources/list"
  def resources_read, do: "resources/read"
  def resources_subscribe, do: "resources/subscribe"
  def resources_unsubscribe, do: "resources/unsubscribe"
  def resources_templates_list, do: "resources/templates/list"
  def prompts_list, do: "prompts/list"
  def prompts_get, do: "prompts/get"
  def logging_set_level, do: "logging/setLevel"
  def completion_complete, do: "completion/complete"
  def subscriptions_listen, do: "subscriptions/listen"

  # Request methods (server → client)
  def sampling_create_message, do: "sampling/createMessage"
  def roots_list, do: "roots/list"
  def elicitation_create, do: "elicitation/create"

  # Notification methods
  def initialized, do: "notifications/initialized"
  def cancelled, do: "notifications/cancelled"
  def progress, do: "notifications/progress"
  def logging_message, do: "notifications/message"
  def tools_list_changed, do: "notifications/tools/list_changed"
  def resources_list_changed, do: "notifications/resources/list_changed"
  def resources_updated, do: "notifications/resources/updated"
  def prompts_list_changed, do: "notifications/prompts/list_changed"
  def roots_list_changed, do: "notifications/roots/list_changed"
  def subscriptions_acknowledged, do: "notifications/subscriptions/acknowledged"
end
