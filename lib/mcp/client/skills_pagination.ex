defmodule MCP.Client.SkillsPagination do
  @moduledoc false

  alias MCP.Protocol.Messages.Skills.ListResult

  @default_max_pages 100
  @default_max_items 10_000
  @default_max_bytes 16_777_216
  @default_timeout 30_000

  @spec list_all(GenServer.server(), keyword()) ::
          {:ok, [MCP.Protocol.Types.Skill.t()]} | {:error, term()}
  def list_all(client, opts) when is_list(opts) do
    with {:ok, bounds} <- bounds(opts),
         {:ok, timeout} <- timeout(opts) do
      deadline = System.monotonic_time(:millisecond) + timeout
      cursor = Keyword.get(opts, :cursor)
      seen = if is_binary(cursor), do: MapSet.new([cursor]), else: MapSet.new()
      state = %{cursor: cursor, seen: seen, chunks: [], pages: 0, items: 0, bytes: 0}
      paginate(client, opts, Map.put(bounds, :timeout, timeout), deadline, state)
    end
  end

  def list_all(_client, opts), do: {:error, {:invalid_pagination_options, opts}}

  defp paginate(_client, _opts, %{max_pages: max_pages}, _deadline, %{pages: pages})
       when pages >= max_pages,
       do: {:error, {:skills_pagination_limit, :pages, max_pages}}

  defp paginate(client, opts, bounds, deadline, state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, {:skills_pagination_limit, :deadline, bounds.timeout}}
    else
      call_opts =
        opts
        |> Keyword.put(:timeout, remaining)
        |> put_cursor(state.cursor)

      case MCP.Client.list_skills(client, call_opts) do
        {:ok, %ListResult{} = result} ->
          consume_page(client, opts, bounds, deadline, result, state)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp consume_page(client, opts, bounds, deadline, result, state) do
    page_items = length(result.skills)

    with {:ok, page_bytes} <- encoded_size(result),
         :ok <- within(:items, state.items + page_items, bounds.max_items),
         :ok <- within(:bytes, state.bytes + page_bytes, bounds.max_bytes),
         :ok <- progressing_page(result.skills, result.next_cursor),
         :ok <- progressing_cursor(result.next_cursor, state.seen) do
      next_state = %{
        cursor: result.next_cursor,
        seen: maybe_put_cursor(state.seen, result.next_cursor),
        chunks: [result.skills | state.chunks],
        pages: state.pages + 1,
        items: state.items + page_items,
        bytes: state.bytes + page_bytes
      }

      case result.next_cursor do
        nil ->
          {:ok, next_state.chunks |> Enum.reverse() |> List.flatten()}

        _next_cursor ->
          paginate(client, opts, bounds, deadline, next_state)
      end
    end
  end

  defp encoded_size(result) do
    case Jason.encode_to_iodata(result) do
      {:ok, encoded} -> {:ok, IO.iodata_length(encoded)}
      {:error, reason} -> {:error, {:invalid_skills_page, reason}}
    end
  rescue
    exception -> {:error, {:invalid_skills_page, exception}}
  end

  defp progressing_page([], cursor) when is_binary(cursor),
    do: {:error, {:skills_pagination_non_progress, cursor}}

  defp progressing_page(_skills, _cursor), do: :ok

  defp progressing_cursor(nil, _seen), do: :ok

  defp progressing_cursor(cursor, seen) do
    if MapSet.member?(seen, cursor),
      do: {:error, {:skills_pagination_cursor_cycle, cursor}},
      else: :ok
  end

  defp maybe_put_cursor(seen, nil), do: seen
  defp maybe_put_cursor(seen, cursor), do: MapSet.put(seen, cursor)

  defp within(_kind, value, limit) when value <= limit, do: :ok
  defp within(kind, _value, limit), do: {:error, {:skills_pagination_limit, kind, limit}}

  defp bounds(opts) do
    values = %{
      max_pages: Keyword.get(opts, :max_pages, @default_max_pages),
      max_items: Keyword.get(opts, :max_items, @default_max_items),
      max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes)
    }

    case Enum.find(values, fn {_key, value} -> not (is_integer(value) and value > 0) end) do
      nil -> {:ok, values}
      {key, value} -> {:error, {:invalid_pagination_bound, key, value}}
    end
  end

  defp timeout(opts) do
    value = Keyword.get(opts, :timeout, @default_timeout)

    if is_integer(value) and value > 0,
      do: {:ok, value},
      else: {:error, {:invalid_pagination_bound, :timeout, value}}
  end

  defp put_cursor(opts, nil), do: Keyword.delete(opts, :cursor)
  defp put_cursor(opts, cursor), do: Keyword.put(opts, :cursor, cursor)
end
