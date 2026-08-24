defmodule MCP.Server.StateHandleTest do
  use ExUnit.Case, async: true

  alias MCP.Server.StateHandle

  setup do
    {:ok, store} = StateHandle.start_link()
    %{store: store}
  end

  test "mint returns an opaque handle that resolves back to the value", %{store: store} do
    handle = StateHandle.mint(store, %{"cursor" => 42})
    assert String.starts_with?(handle, "sh_")
    assert StateHandle.fetch(store, handle) == {:ok, %{"cursor" => 42}}
  end

  test "distinct mints get distinct handles; each resolves to its own value", %{store: store} do
    h1 = StateHandle.mint(store, :a)
    h2 = StateHandle.mint(store, :b)
    assert h1 != h2
    assert StateHandle.fetch(store, h1) == {:ok, :a}
    assert StateHandle.fetch(store, h2) == {:ok, :b}
  end

  test "an unminted or non-binary handle does not resolve", %{store: store} do
    assert StateHandle.fetch(store, "sh_nope") == :error
    assert StateHandle.fetch(store, nil) == :error
  end

  test "delete removes a handle", %{store: store} do
    handle = StateHandle.mint(store, :x)
    assert :ok = StateHandle.delete(store, handle)
    assert :error = StateHandle.delete(store, handle)
    assert StateHandle.fetch(store, handle) == :error
  end

  test "principal-bound handles reject a different principal", %{store: store} do
    handle = StateHandle.mint(store, :secret, %{subject: "alice"})

    assert StateHandle.fetch(store, handle, %{subject: "alice"}) == {:ok, :secret}
    assert StateHandle.fetch(store, handle, %{subject: "mallory"}) == :error
    assert StateHandle.fetch(store, handle) == :error

    assert :error = StateHandle.delete(store, handle)
    assert StateHandle.fetch(store, handle, %{subject: "alice"}) == {:ok, :secret}

    assert :ok = StateHandle.delete(store, handle, %{subject: "alice"})
    assert :error = StateHandle.delete(store, handle, %{subject: "alice"})
    assert StateHandle.fetch(store, handle, %{subject: "alice"}) == :error
  end

  test "consume has exactly one winner under concurrency", %{store: store} do
    handle = StateHandle.mint(store, :once, :alice)

    results =
      1..20
      |> Task.async_stream(fn _ -> StateHandle.consume(store, handle, :alice) end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == {:ok, :once})) == 1
    assert Enum.count(results, &(&1 == :error)) == 19
  end

  test "handles expire", _context do
    {:ok, store} = StateHandle.start_link(ttl_ms: 1)
    handle = StateHandle.mint(store, :short_lived)
    Process.sleep(2)
    assert StateHandle.fetch(store, handle) == :error
  end

  test "capacity evicts the oldest live handle", _context do
    {:ok, store} = StateHandle.start_link(max_entries: 1)
    first = StateHandle.mint(store, :first)
    second = StateHandle.mint(store, :second)

    assert StateHandle.fetch(store, first) == :error
    assert StateHandle.fetch(store, second) == {:ok, :second}
  end

  test "expiry and insertion indexes stay synchronized after removal", %{store: store} do
    handle = StateHandle.mint(store, :value, :alice)
    assert StateHandle.consume(store, handle, :alice) == {:ok, :value}

    state = Agent.get(store, & &1)
    assert state.entries == %{}
    assert :gb_sets.is_empty(state.expirations)
    assert :gb_sets.is_empty(state.insertion_order)
  end

  test "rejects invalid bounds" do
    assert StateHandle.start_link(max_entries: 0) ==
             {:error, {:invalid_option, :max_entries, 0}}

    assert StateHandle.start_link(ttl_ms: :infinity) ==
             {:error, {:invalid_option, :ttl_ms, :infinity}}
  end
end
