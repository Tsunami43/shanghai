defmodule Storage.Snapshot.ManagerTest do
  use ExUnit.Case, async: false

  alias Storage.Snapshot.Manager
  alias Storage.WAL.{Writer, SegmentManager}
  alias Storage.Index.SegmentIndex
  alias Storage.Snapshot.Writer, as: SnapshotWriter

  @test_dir Path.join(
              System.tmp_dir!(),
              "shanghai_snapshot_manager_test_#{:rand.uniform(999_999)}"
            )
  @snapshots_dir Path.join(@test_dir, "snapshots")
  @wal_dir Path.join(@test_dir, "wal")
  @index_dir Path.join(@test_dir, "index")
  @registry Storage.WAL.SegmentRegistry

  setup_all do
    # Start Registry
    {:ok, _} = Registry.start_link(keys: :unique, name: @registry)

    # Start SegmentManager
    {:ok, _} = SegmentManager.start_link(:ok)

    :ok
  end

  setup do
    # Clean up test directory
    File.rm_rf(@test_dir)
    File.mkdir_p!(@snapshots_dir)
    File.mkdir_p!(@wal_dir)
    File.mkdir_p!(@index_dir)

    # Start SegmentIndex
    {:ok, index_pid} = SegmentIndex.start_link(data_dir: @index_dir)

    # Start WAL Writer
    {:ok, writer_pid} =
      Writer.start_link(
        data_dir: @wal_dir,
        node_id: "test_node",
        segment_size_threshold: 10 * 1024 * 1024,
        segment_time_threshold: 3600
      )

    # Start WAL Reader
    {:ok, reader_pid} = Storage.WAL.Reader.start_link([])

    # Start Snapshot Manager
    {:ok, manager_pid} =
      Manager.start_link(
        snapshots_dir: @snapshots_dir,
        retention_count: 5
      )

    on_exit(fn ->
      if Process.alive?(manager_pid), do: GenServer.stop(manager_pid)
      if Process.alive?(reader_pid), do: GenServer.stop(reader_pid)
      if Process.alive?(writer_pid), do: GenServer.stop(writer_pid)
      if Process.alive?(index_pid), do: GenServer.stop(index_pid)

      # Stop all segments
      SegmentManager.list_segments()
      |> Enum.each(fn {id, _pid} ->
        SegmentManager.stop_segment(id)
      end)

      File.rm_rf(@test_dir)
    end)

    {:ok, manager: manager_pid, writer: writer_pid, reader: reader_pid, index: index_pid}
  end

  describe "start_link/1" do
    test "starts with default retention count" do
      {:ok, pid} =
        Manager.start_link(
          snapshots_dir: Path.join(@test_dir, "other_snapshots"),
          name: :test_manager
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts with custom retention count" do
      {:ok, pid} =
        Manager.start_link(
          snapshots_dir: Path.join(@test_dir, "other_snapshots"),
          retention_count: 10,
          name: :test_manager_2
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "creates snapshots directory if it doesn't exist" do
      new_dir = Path.join(@test_dir, "new_snapshots")
      refute File.exists?(new_dir)

      {:ok, pid} =
        Manager.start_link(
          snapshots_dir: new_dir,
          name: :test_manager_3
        )

      assert File.exists?(new_dir)
      GenServer.stop(pid)
    end
  end

  describe "create_snapshot/1" do
    test "creates snapshot via manager", %{manager: _manager, writer: _writer} do
      # Write data
      {:ok, lsn} = Writer.append("test data")
      Process.sleep(10)

      # Create snapshot via manager
      assert {:ok, snapshot_id} = Manager.create_snapshot(lsn)
      assert String.starts_with?(snapshot_id, "snapshot_")

      # Verify snapshot exists
      assert {:ok, snapshots} = Manager.list_snapshots()
      assert length(snapshots) == 1
      assert hd(snapshots).snapshot_id == snapshot_id
    end

    test "creates multiple snapshots", %{manager: _manager, writer: _writer} do
      # Create multiple snapshots
      snapshot_ids =
        for i <- 1..3 do
          {:ok, lsn} = Writer.append("entry #{i}")
          Process.sleep(10)
          {:ok, snapshot_id} = Manager.create_snapshot(lsn)
          snapshot_id
        end

      # Verify all exist
      assert {:ok, snapshots} = Manager.list_snapshots()
      assert length(snapshots) == 3

      listed_ids = Enum.map(snapshots, & &1.snapshot_id)
      assert Enum.sort(listed_ids) == Enum.sort(snapshot_ids)
    end

    test "creates empty snapshot for non-existent LSN", %{manager: _manager} do
      # Creating snapshot with LSN that doesn't exist creates empty snapshot
      assert {:ok, snapshot_id} = Manager.create_snapshot(999_999)

      # Verify it exists in list
      assert {:ok, snapshots} = Manager.list_snapshots()
      assert Enum.any?(snapshots, &(&1.snapshot_id == snapshot_id))

      # Verify metadata shows 0 entries
      assert {:ok, info} = Manager.get_snapshot_info(snapshot_id)
      assert info.entry_count == 0
    end
  end

  describe "list_snapshots/0" do
    test "returns empty list when no snapshots exist", %{manager: _manager} do
      assert {:ok, []} = Manager.list_snapshots()
    end

    test "lists all created snapshots", %{manager: _manager, writer: _writer} do
      # Create snapshots
      for i <- 1..5 do
        {:ok, _lsn} = Writer.append("entry #{i}")
        Process.sleep(10)
        {:ok, _snapshot_id} = Manager.create_snapshot(i - 1)
      end

      assert {:ok, snapshots} = Manager.list_snapshots()
      assert length(snapshots) == 5

      # Verify sorted by LSN descending
      lsns = Enum.map(snapshots, & &1.lsn)
      assert lsns == Enum.sort(lsns, :desc)
    end

    test "snapshot list includes metadata", %{manager: _manager, writer: _writer} do
      {:ok, lsn} = Writer.append("test")
      Process.sleep(10)
      {:ok, _snapshot_id} = Manager.create_snapshot(lsn)

      assert {:ok, [snapshot]} = Manager.list_snapshots()

      assert is_binary(snapshot.snapshot_id)
      assert snapshot.lsn == lsn
      assert is_integer(snapshot.entry_count)
      assert %DateTime{} = snapshot.created_at
      assert is_integer(snapshot.compressed_size)
      assert is_integer(snapshot.uncompressed_size)
    end
  end

  describe "cleanup_old_snapshots/0" do
    test "deletes no snapshots when under retention limit", %{manager: _manager, writer: _writer} do
      # Create 3 snapshots (under limit of 5)
      for i <- 1..3 do
        {:ok, _lsn} = Writer.append("entry #{i}")
        Process.sleep(10)
        {:ok, _snapshot_id} = Manager.create_snapshot(i - 1)
      end

      assert {:ok, deleted_count} = Manager.cleanup_old_snapshots()
      assert deleted_count == 0

      # All snapshots should still exist
      assert {:ok, snapshots} = Manager.list_snapshots()
      assert length(snapshots) == 3
    end

    test "deletes snapshots exceeding retention count", %{manager: _manager, writer: _writer} do
      # Create 8 snapshots (exceeds limit of 5)
      for i <- 1..8 do
        {:ok, _lsn} = Writer.append("entry #{i}")
        Process.sleep(10)
        {:ok, _snapshot_id} = Manager.create_snapshot(i - 1)
      end

      assert {:ok, deleted_count} = Manager.cleanup_old_snapshots()
      assert deleted_count == 3

      # Should keep only 5 most recent
      assert {:ok, snapshots} = Manager.list_snapshots()
      assert length(snapshots) == 5
    end

    test "keeps most recent snapshots", %{manager: _manager, writer: _writer} do
      # Create 7 snapshots
      snapshot_ids =
        for i <- 1..7 do
          {:ok, _lsn} = Writer.append("entry #{i}")
          Process.sleep(10)
          {:ok, snapshot_id} = Manager.create_snapshot(i - 1)
          snapshot_id
        end

      # Cleanup
      assert {:ok, 2} = Manager.cleanup_old_snapshots()

      # Verify newest 5 remain
      assert {:ok, remaining} = Manager.list_snapshots()
      assert length(remaining) == 5

      remaining_ids = Enum.map(remaining, & &1.snapshot_id)
      newest_5 = Enum.take(snapshot_ids, -5)

      assert Enum.sort(remaining_ids) == Enum.sort(newest_5)
    end

    test "deletes both data and metadata files", %{manager: _manager, writer: _writer} do
      # Create 6 snapshots
      for i <- 1..6 do
        {:ok, _lsn} = Writer.append("entry #{i}")
        Process.sleep(10)
        {:ok, _snapshot_id} = Manager.create_snapshot(i - 1)
      end

      # Get oldest snapshot ID
      {:ok, snapshots_before} = Manager.list_snapshots()
      oldest = List.last(snapshots_before)

      # Cleanup
      assert {:ok, 1} = Manager.cleanup_old_snapshots()

      # Verify files deleted
      {data_path, meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, oldest.snapshot_id)
      refute File.exists?(data_path)
      refute File.exists?(meta_path)
    end

    test "handles concurrent cleanup calls", %{manager: _manager, writer: _writer} do
      # Create snapshots
      for i <- 1..10 do
        {:ok, _lsn} = Writer.append("entry #{i}")
        Process.sleep(10)
        {:ok, _snapshot_id} = Manager.create_snapshot(i - 1)
      end

      # Concurrent cleanup
      tasks =
        for _i <- 1..3 do
          Task.async(fn ->
            Manager.cleanup_old_snapshots()
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _count} -> true
               _ -> false
             end)

      # Should have 5 remaining
      assert {:ok, snapshots} = Manager.list_snapshots()
      assert length(snapshots) == 5
    end
  end

  describe "get_snapshot_info/1" do
    test "returns info for existing snapshot", %{manager: _manager, writer: _writer} do
      {:ok, lsn} = Writer.append("test data")
      Process.sleep(10)
      {:ok, snapshot_id} = Manager.create_snapshot(lsn)

      assert {:ok, info} = Manager.get_snapshot_info(snapshot_id)

      assert info.snapshot_id == snapshot_id
      assert info.lsn == lsn
      assert info.entry_count == 1
      assert %DateTime{} = info.created_at
      assert is_integer(info.checksum)
      assert is_integer(info.compressed_size)
      assert is_integer(info.uncompressed_size)
    end

    test "returns error for non-existent snapshot", %{manager: _manager} do
      assert {:error, _reason} = Manager.get_snapshot_info("non_existent_snapshot")
    end
  end

  describe "retention policy" do
    test "respects custom retention count" do
      custom_dir = Path.join(@test_dir, "custom_retention")

      {:ok, manager_pid} =
        Manager.start_link(
          snapshots_dir: custom_dir,
          retention_count: 3,
          name: :custom_manager
        )

      # Write data
      for i <- 1..5 do
        {:ok, _lsn} = Writer.append("entry #{i}")
        Process.sleep(10)
        {:ok, _snapshot_id} = GenServer.call(manager_pid, {:create_snapshot, i - 1})
      end

      Process.sleep(10)

      # Cleanup with retention=3
      assert {:ok, 2} = GenServer.call(manager_pid, :cleanup_old_snapshots)

      # Should have 3 remaining
      assert {:ok, snapshots} = GenServer.call(manager_pid, :list_snapshots)
      assert length(snapshots) == 3

      GenServer.stop(manager_pid)
    end

    test "retention count of 0 keeps no snapshots" do
      zero_dir = Path.join(@test_dir, "zero_retention")

      {:ok, manager_pid} =
        Manager.start_link(
          snapshots_dir: zero_dir,
          retention_count: 0,
          name: :zero_manager
        )

      # Create snapshots
      for i <- 1..3 do
        {:ok, _lsn} = Writer.append("entry #{i}")
        Process.sleep(10)
        {:ok, _snapshot_id} = GenServer.call(manager_pid, {:create_snapshot, i - 1})
      end

      Process.sleep(10)

      # Cleanup should delete all
      assert {:ok, 3} = GenServer.call(manager_pid, :cleanup_old_snapshots)

      assert {:ok, []} = GenServer.call(manager_pid, :list_snapshots)

      GenServer.stop(manager_pid)
    end

    test "retention count of 1 keeps only newest", %{writer: _writer} do
      one_dir = Path.join(@test_dir, "one_retention")

      {:ok, manager_pid} =
        Manager.start_link(
          snapshots_dir: one_dir,
          retention_count: 1,
          name: :one_manager
        )

      # Create snapshots
      snapshot_ids =
        for i <- 1..5 do
          {:ok, _lsn} = Writer.append("entry #{i}")
          Process.sleep(10)
          {:ok, snapshot_id} = GenServer.call(manager_pid, {:create_snapshot, i - 1})
          snapshot_id
        end

      Process.sleep(10)

      # Cleanup
      assert {:ok, 4} = GenServer.call(manager_pid, :cleanup_old_snapshots)

      # Should keep only newest
      assert {:ok, [snapshot]} = GenServer.call(manager_pid, :list_snapshots)
      assert snapshot.snapshot_id == List.last(snapshot_ids)

      GenServer.stop(manager_pid)
    end
  end

  describe "error handling" do
    test "handles missing snapshot directory gracefully", %{manager: _manager} do
      # List should return empty
      assert {:ok, []} = Manager.list_snapshots()
    end

    test "continues cleanup despite individual file errors", %{manager: _manager, writer: _writer} do
      # Create snapshots
      for i <- 1..7 do
        {:ok, _lsn} = Writer.append("entry #{i}")
        Process.sleep(10)
        {:ok, _snapshot_id} = Manager.create_snapshot(i - 1)
      end

      # Get snapshots before cleanup
      {:ok, snapshots_before} = Manager.list_snapshots()
      oldest = List.last(snapshots_before)

      # Make one file undeletable by making directory read-only
      # (Skip on systems where this doesn't work)
      {data_path, _meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, oldest.snapshot_id)

      # Try to make file read-only
      :ok = File.chmod(data_path, 0o444)

      # Cleanup should still succeed (may skip undeletable files)
      assert {:ok, _deleted_count} = Manager.cleanup_old_snapshots()

      # Restore permissions if file still exists (on some systems read-only doesn't prevent deletion)
      if File.exists?(data_path) do
        :ok = File.chmod(data_path, 0o644)
      end
    end
  end

  describe "concurrent operations" do
    test "handles concurrent snapshot creation", %{manager: _manager, writer: _writer} do
      # Write data
      for i <- 1..10 do
        {:ok, _lsn} = Writer.append("entry #{i}")
      end

      Process.sleep(10)

      # Create snapshots concurrently
      tasks =
        for i <- 0..4 do
          Task.async(fn ->
            Manager.create_snapshot(i * 2)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _snapshot_id} -> true
               _ -> false
             end)

      # Should have 5 snapshots
      assert {:ok, snapshots} = Manager.list_snapshots()
      assert length(snapshots) == 5
    end

    test "handles create and cleanup concurrently", %{manager: _manager, writer: _writer} do
      # Create initial snapshots
      for i <- 1..10 do
        {:ok, _lsn} = Writer.append("entry #{i}")
        Process.sleep(5)
        {:ok, _snapshot_id} = Manager.create_snapshot(i - 1)
      end

      # Run cleanup and create concurrently
      cleanup_task = Task.async(fn -> Manager.cleanup_old_snapshots() end)

      create_task =
        Task.async(fn ->
          {:ok, _lsn} = Writer.append("new entry")
          Process.sleep(5)
          Manager.create_snapshot(10)
        end)

      {:ok, _deleted} = Task.await(cleanup_task)
      {:ok, _snapshot_id} = Task.await(create_task)

      # Should have at most 6 snapshots (5 from cleanup + 1 new)
      assert {:ok, snapshots} = Manager.list_snapshots()
      assert length(snapshots) <= 6
    end

    test "handles concurrent list and cleanup", %{manager: _manager, writer: _writer} do
      # Create snapshots
      for i <- 1..8 do
        {:ok, _lsn} = Writer.append("entry #{i}")
        Process.sleep(5)
        {:ok, _snapshot_id} = Manager.create_snapshot(i - 1)
      end

      # List and cleanup concurrently
      list_task = Task.async(fn -> Manager.list_snapshots() end)
      cleanup_task = Task.async(fn -> Manager.cleanup_old_snapshots() end)

      {:ok, snapshots} = Task.await(list_task)
      {:ok, _deleted} = Task.await(cleanup_task)

      # List should have succeeded
      assert is_list(snapshots)
      assert length(snapshots) > 0
    end
  end

  describe "integration" do
    test "full lifecycle: create, list, cleanup", %{manager: _manager, writer: _writer} do
      # Create data
      for i <- 1..10 do
        {:ok, _lsn} = Writer.append("entry #{i}")
      end

      Process.sleep(10)

      # Create snapshots
      snapshot_ids =
        for i <- 0..9 do
          {:ok, snapshot_id} = Manager.create_snapshot(i)
          snapshot_id
        end

      # Verify creation
      assert {:ok, snapshots} = Manager.list_snapshots()
      assert length(snapshots) == 10

      # Cleanup
      assert {:ok, 5} = Manager.cleanup_old_snapshots()

      # Verify cleanup
      assert {:ok, remaining} = Manager.list_snapshots()
      assert length(remaining) == 5

      # Verify correct snapshots remain (newest 5)
      remaining_ids = Enum.map(remaining, & &1.snapshot_id)
      newest_5 = Enum.take(snapshot_ids, -5)
      assert Enum.sort(remaining_ids) == Enum.sort(newest_5)

      # Get info for remaining snapshot
      first_remaining = hd(remaining)
      assert {:ok, info} = Manager.get_snapshot_info(first_remaining.snapshot_id)
      assert info.snapshot_id == first_remaining.snapshot_id
    end

    test "create after cleanup maintains retention", %{manager: _manager, writer: _writer} do
      # Create 10 snapshots
      for i <- 1..10 do
        {:ok, _lsn} = Writer.append("entry #{i}")
        Process.sleep(5)
        {:ok, _snapshot_id} = Manager.create_snapshot(i - 1)
      end

      # Cleanup to 5
      assert {:ok, 5} = Manager.cleanup_old_snapshots()

      # Create 3 more
      for i <- 11..13 do
        {:ok, _lsn} = Writer.append("entry #{i}")
        Process.sleep(5)
        {:ok, _snapshot_id} = Manager.create_snapshot(i - 1)
      end

      # Should have 8 total
      assert {:ok, snapshots} = Manager.list_snapshots()
      assert length(snapshots) == 8

      # Cleanup again
      assert {:ok, 3} = Manager.cleanup_old_snapshots()

      # Should have 5
      assert {:ok, final_snapshots} = Manager.list_snapshots()
      assert length(final_snapshots) == 5
    end
  end
end
