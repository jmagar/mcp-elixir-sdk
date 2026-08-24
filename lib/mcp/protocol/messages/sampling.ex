defmodule MCP.Protocol.Messages.Sampling do
  @moduledoc """
  Message types for `sampling/createMessage`.
  """

  defmodule CreateMessageParams do
    @moduledoc """
    Parameters for `sampling/createMessage`.
    """

    alias MCP.Protocol.Types.{ModelPreferences, SamplingMessage}

    defstruct [
      :messages,
      :model_preferences,
      :system_prompt,
      :include_context,
      :temperature,
      :max_tokens,
      :stop_sequences,
      :metadata,
      :meta
    ]

    @type t :: %__MODULE__{
            messages: [SamplingMessage.t()],
            model_preferences: ModelPreferences.t() | nil,
            system_prompt: String.t() | nil,
            include_context: String.t() | nil,
            temperature: float() | nil,
            max_tokens: integer(),
            stop_sequences: [String.t()] | nil,
            metadata: map() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        messages: map |> Map.fetch!("messages") |> Enum.map(&SamplingMessage.from_map/1),
        model_preferences: map |> Map.get("modelPreferences") |> parse_model_preferences(),
        system_prompt: Map.get(map, "systemPrompt"),
        include_context: Map.get(map, "includeContext"),
        temperature: Map.get(map, "temperature"),
        max_tokens: Map.fetch!(map, "maxTokens"),
        stop_sequences: Map.get(map, "stopSequences"),
        metadata: Map.get(map, "metadata"),
        meta: Map.get(map, "_meta")
      }
    end

    defp parse_model_preferences(nil), do: nil
    defp parse_model_preferences(map), do: ModelPreferences.from_map(map)

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{
          messages: struct.messages,
          maxTokens: struct.max_tokens
        }

        map =
          struct
          |> Map.from_struct()
          |> Enum.reduce(map, fn
            {:messages, _}, acc -> acc
            {:max_tokens, _}, acc -> acc
            {_key, nil}, acc -> acc
            {:model_preferences, val}, acc -> Map.put(acc, :modelPreferences, val)
            {:system_prompt, val}, acc -> Map.put(acc, :systemPrompt, val)
            {:include_context, val}, acc -> Map.put(acc, :includeContext, val)
            {:stop_sequences, val}, acc -> Map.put(acc, :stopSequences, val)
            {:meta, val}, acc -> Map.put(acc, :_meta, val)
            {key, val}, acc -> Map.put(acc, key, val)
          end)

        Jason.Encode.map(map, opts)
      end
    end
  end

  defmodule CreateMessageResult do
    @moduledoc """
    Result of `sampling/createMessage`.
    """

    alias MCP.Protocol.OpenObject
    alias MCP.Protocol.Types.Content

    @known_keys ["role", "content", "model", "stopReason", "_meta"]

    defstruct [:role, :content, :model, :stop_reason, :meta, extra: %{}]

    @type t :: %__MODULE__{
            role: String.t(),
            content: Content.content_block(),
            model: String.t(),
            stop_reason: String.t() | nil,
            meta: map() | nil,
            extra: %{optional(String.t()) => MCP.Protocol.json_value()}
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        role: Map.fetch!(map, "role"),
        content: map |> Map.fetch!("content") |> Content.from_map(),
        model: Map.fetch!(map, "model"),
        stop_reason: Map.get(map, "stopReason"),
        meta: Map.get(map, "_meta"),
        extra: OpenObject.extra(map, @known_keys)
      }
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = result) do
      %{"role" => result.role, "content" => result.content, "model" => result.model}
      |> maybe_put("stopReason", result.stop_reason)
      |> maybe_put("_meta", result.meta)
      |> OpenObject.merge!(result.extra, @known_keys, "sampling/createMessage result")
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        Jason.Encode.map(@for.to_map(struct), opts)
      end
    end
  end
end
