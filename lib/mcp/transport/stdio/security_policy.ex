defmodule MCP.Transport.Stdio.SecurityPolicy do
  @moduledoc """
  Validated framing, diagnostics, environment, and shutdown policy for stdio.

  Process-tree cleanup is cooperative: Linux descendants are identified by
  ancestry and a per-launch inherited marker. A hostile command can discard
  that marker, so untrusted executables require an external cgroup or sandbox.
  """

  defstruct max_frame_bytes: 1_000_000,
            max_pending_stdout_bytes: 4_000_000,
            max_frames_per_turn: 100,
            stderr: :disable,
            max_stderr_bytes: 64_000,
            environment: :inherit,
            shutdown_timeout: 5_000

  @type t :: %__MODULE__{
          max_frame_bytes: pos_integer(),
          max_pending_stdout_bytes: pos_integer(),
          max_frames_per_turn: pos_integer(),
          stderr: :capture | :console | :disable,
          max_stderr_bytes: pos_integer(),
          environment: :replace | :inherit,
          shutdown_timeout: pos_integer()
        }

  @keys [
    :max_frame_bytes,
    :max_pending_stdout_bytes,
    :max_frames_per_turn,
    :stderr,
    :max_stderr_bytes,
    :environment,
    :shutdown_timeout
  ]
  @positive_keys [
    :max_frame_bytes,
    :max_pending_stdout_bytes,
    :max_frames_per_turn,
    :max_stderr_bytes,
    :shutdown_timeout
  ]

  @spec default() :: t()
  def default, do: %__MODULE__{}

  @spec gateway() :: t()
  def gateway, do: %__MODULE__{environment: :replace}

  @spec new(keyword() | t()) :: {:ok, t()} | {:error, {:invalid_security_policy, term()}}
  def new(opts \\ [])

  def new(%__MODULE__{} = policy) do
    case validate(policy) do
      :ok -> {:ok, policy}
      {:error, reason} -> {:error, {:invalid_security_policy, reason}}
    end
  end

  def new(opts) when is_list(opts) do
    unknown = Keyword.keys(opts) -- @keys

    with [] <- unknown,
         policy <- struct(default(), opts),
         :ok <- validate(policy) do
      {:ok, policy}
    else
      [_ | _] = keys -> {:error, {:invalid_security_policy, {:unknown_options, keys}}}
      {:error, reason} -> {:error, {:invalid_security_policy, reason}}
    end
  end

  defp validate(policy) do
    invalid_positive =
      Enum.find(@positive_keys, fn key ->
        value = Map.fetch!(policy, key)
        not (is_integer(value) and value > 0)
      end)

    cond do
      invalid_positive ->
        {:error, {invalid_positive, Map.fetch!(policy, invalid_positive)}}

      policy.stderr not in [:capture, :console, :disable] ->
        {:error, {:stderr, policy.stderr}}

      policy.environment not in [:replace, :inherit] ->
        {:error, {:environment, policy.environment}}

      true ->
        :ok
    end
  end
end
