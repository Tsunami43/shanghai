defmodule Query.StoreTest do
  @moduledoc """
  Integration tests for the durable path of `Query.Store`.

  These boot a real WAL stack in a temporary directory, exercise the store
  against it, then start a fresh store instance to prove that state is
  recovered from the log after a restart.
  """

  use ExUnit.Case, async: false

  alias Storage.Index.SegmentIndex
  alias Storage.WAL.{Reader, SegmentManager, Writer}

  @registry Storage.WAL.SegmentRegistry

  setup_all do
    # Long-lived WAL infrastructure shared by the test; kept out of the
    # per-test process so it is still alive during on_exit cleanup.
    ensure_started(fn -> Registry.start_link(keys: :unique, name: @registry) end)
    ensure_started(fn -> SegmentManager.start_link(:ok) end)
    :ok
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "shanghai_query_store_test_#{:rand.uniform(999_999)}")
    File.rm_rf(dir)
    File.mkdir_p!(dir)

    # start_supervised! gives synchronous, deterministic teardown so the named
    # WAL singletons never linger into another test module.
    start_supervised!({SegmentIndex, data_dir: Path.join(dir, "index")})

    start_supervised!(
      {Writer,
       [
         data_dir: dir,
         node_id: "test_node",
         segment_size_threshold: 10 * 1024 * 1024,
         segment_time_threshold: 3600
       ]}
    )

    start_supervised!({Reader, []})

    on_exit(fn ->
      Enum.each(SegmentManager.list_segments(), fn {id, _pid} ->
        SegmentManager.stop_segment(id)
      end)

      File.rm_rf(dir)
    end)

    :ok
  end

  test "persists writes to the WAL and recovers them after a restart" do
    {:ok, store_a} = Query.Store.start_link(name: :store_a, table: :qs_test_a)

    # The store detects the running WAL and switches to durable mode.
    assert {:ok, %{durable: true}} = Query.Store.info(store_a)

    {:ok, :written} = Query.Store.put(store_a, "user:1", %{name: "Alice"})
    {:ok, :written} = Query.Store.put(store_a, "user:2", %{name: "Bob"})
    {:ok, :deleted} = Query.Store.delete(store_a, "user:2")

    {:ok, :committed} =
      Query.Store.transact(store_a, [
        {:write, "account:1", 100},
        {:write, "account:2", 50}
      ])

    :ok = GenServer.stop(store_a)

    # A brand new store instance recovers state purely from the WAL.
    {:ok, store_b} = Query.Store.start_link(name: :store_b, table: :qs_test_b)

    assert {:ok, %{durable: true, recovered: recovered}} = Query.Store.info(store_b)
    assert recovered > 0

    assert {:ok, %{name: "Alice"}} = Query.Store.get(store_b, "user:1")
    # Deleted key must stay deleted after recovery.
    assert {:error, :not_found} = Query.Store.get(store_b, "user:2")
    # Transaction results survive recovery.
    assert {:ok, 100} = Query.Store.get(store_b, "account:1")
    assert {:ok, 50} = Query.Store.get(store_b, "account:2")

    :ok = GenServer.stop(store_b)
  end

  test "atomic key operations survive recovery" do
    {:ok, store_a} = Query.Store.start_link(name: :store_ra, table: :qs_test_ra)

    {:ok, :written} = Query.Store.put(store_a, "src", "value")
    {:ok, :renamed} = Query.Store.rename(store_a, "src", "dst")

    {:ok, :written} = Query.Store.put(store_a, "x", 1)
    {:ok, :written} = Query.Store.put(store_a, "y", 2)
    {:ok, :swapped} = Query.Store.swap(store_a, "x", "y")

    {:ok, :written} = Query.Store.put(store_a, "tpl", "t")
    {:ok, :copied} = Query.Store.copy(store_a, "tpl", "cpy")

    {:ok, :written} = Query.Store.put(store_a, "p:1", 1)
    {:ok, :written} = Query.Store.put(store_a, "p:2", 2)
    {:ok, {:deleted, 2}} = Query.Store.delete_prefix(store_a, "p:")

    :ok = GenServer.stop(store_a)

    {:ok, store_b} = Query.Store.start_link(name: :store_rb, table: :qs_test_rb)

    # rename moved the value
    assert {:error, :not_found} = Query.Store.get(store_b, "src")
    assert {:ok, "value"} = Query.Store.get(store_b, "dst")
    # swap exchanged the values
    assert {:ok, 2} = Query.Store.get(store_b, "x")
    assert {:ok, 1} = Query.Store.get(store_b, "y")
    # copy duplicated the value, keeping the source
    assert {:ok, "t"} = Query.Store.get(store_b, "tpl")
    assert {:ok, "t"} = Query.Store.get(store_b, "cpy")
    # delete_prefix removed the range
    assert {:error, :not_found} = Query.Store.get(store_b, "p:1")
    assert {:error, :not_found} = Query.Store.get(store_b, "p:2")

    :ok = GenServer.stop(store_b)
  end

  # Starts a process, tolerating the case where it is already running.
  defp ensure_started(fun) do
    case fun.() do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end
end
