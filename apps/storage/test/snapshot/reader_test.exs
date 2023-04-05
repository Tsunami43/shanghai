defmodule Storage.Snapshot.ReaderTest do
  use ExUnit.Case, async: false

  alias Storage.Snapshot.Reader, as: SnapshotReader
  alias Storage.Snapshot.Writer, as: SnapshotWriter
  alias Storage.WAL.Writer, as: WALWriter
  alias Storage.WAL.Reader, as: WALReader
  alias Storage.WAL.SegmentManager
  alias Storage.Index.SegmentIndex

  @test_dir Path.join(System.tmp_dir!(), "shanghai_snapshot_reader_test_#{:rand.uniform(999_999)}")
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
      WALWriter.start_link(
        data_dir: @wal_dir,
        node_id: "test_node",
        segment_size_threshold: 10 * 1024 * 1024,
        segment_time_threshold: 3600
      )

    # Start WAL Reader
    {:ok, reader_pid} = WALReader.start_link([])

    on_exit(fn ->
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

    {:ok, writer: writer_pid, reader: reader_pid, index: index_pid}
  end

  describe "read_snapshot/2" do
    test "reads snapshot with no entries", %{} do
      # Create empty snapshot
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, 0)

      # Read it back
      assert {:ok, entries} = SnapshotReader.read_snapshot(@snapshots_dir, snapshot_id)
      assert entries == []
    end

    test "reads snapshot with single entry", %{writer: _writer} do
      # Write and snapshot
      {:ok, lsn} = WALWriter.append("test data")
      Process.sleep(10)
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      # Read snapshot
      assert {:ok, entries} = SnapshotReader.read_snapshot(@snapshots_dir, snapshot_id)
      assert length(entries) == 1
      assert hd(entries).data == "test data"
    end

    test "reads snapshot with multiple entries", %{writer: _writer} do
      # Write entries
      test_data = ["entry 1", "entry 2", "entry 3", "entry 4", "entry 5"]

      lsns =
        Enum.map(test_data, fn data ->
          {:ok, lsn} = WALWriter.append(data)
          lsn
        end)

      last_lsn = List.last(lsns)
      Process.sleep(10)

      # Create snapshot
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, last_lsn)

      # Read snapshot
      assert {:ok, entries} = SnapshotReader.read_snapshot(@snapshots_dir, snapshot_id)
      assert length(entries) == 5

      # Verify data
      entry_data = Enum.map(entries, & &1.data)
      assert entry_data == test_data
    end

    test "reads snapshot with various data types", %{writer: _writer} do
      test_data = [
        "string",
        12345,
        %{key: "value"},
        [1, 2, 3],
        {:tuple, "data"}
      ]

      lsns =
        Enum.map(test_data, fn data ->
          {:ok, lsn} = WALWriter.append(data)
          lsn
        end)

      last_lsn = List.last(lsns)
      Process.sleep(10)

      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, last_lsn)

      # Read and verify
      assert {:ok, entries} = SnapshotReader.read_snapshot(@snapshots_dir, snapshot_id)
      assert length(entries) == 5

      entry_data = Enum.map(entries, & &1.data)
      assert entry_data == test_data
    end

    test "returns error for non-existent snapshot", %{} do
      assert {:error, _reason} = SnapshotReader.read_snapshot(@snapshots_dir, "non_existent_snapshot")
    end

    test "returns error for corrupt data file", %{writer: _writer} do
      # Create valid snapshot
      {:ok, lsn} = WALWriter.append("test")
      Process.sleep(10)
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      # Corrupt data file
      {data_path, _meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, snapshot_id)
      File.write!(data_path, "corrupted data")

      # Should detect corruption via checksum
      assert {:error, :corrupt_snapshot} = SnapshotReader.read_snapshot(@snapshots_dir, snapshot_id)
    end

    test "returns error for corrupt metadata file", %{writer: _writer} do
      # Create valid snapshot
      {:ok, lsn} = WALWriter.append("test")
      Process.sleep(10)
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      # Corrupt metadata file
      {_data_path, meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, snapshot_id)
      File.write!(meta_path, "corrupted metadata")

      # Should fail to deserialize metadata
      assert {:error, _reason} = SnapshotReader.read_snapshot(@snapshots_dir, snapshot_id)
    end
  end

  describe "list_snapshots/1" do
    test "returns empty list when no snapshots exist", %{} do
      assert {:ok, []} = SnapshotReader.list_snapshots(@snapshots_dir)
    end

    test "returns empty list when directory doesn't exist", %{} do
      non_existent = Path.join(@test_dir, "non_existent")
      assert {:ok, []} = SnapshotReader.list_snapshots(non_existent)
    end

    test "lists single snapshot", %{writer: _writer} do
      {:ok, lsn} = WALWriter.append("test")
      Process.sleep(10)
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      assert {:ok, snapshots} = SnapshotReader.list_snapshots(@snapshots_dir)
      assert length(snapshots) == 1

      snapshot = hd(snapshots)
      assert snapshot.snapshot_id == snapshot_id
      assert snapshot.lsn == lsn
      assert snapshot.entry_count == 1
      assert %DateTime{} = snapshot.created_at
    end

    test "lists multiple snapshots sorted by LSN descending", %{writer: _writer} do
      # Create multiple snapshots
      snapshot_ids =
        for i <- 1..5 do
          {:ok, lsn} = WALWriter.append("entry #{i}")
          Process.sleep(10)
          {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)
          snapshot_id
        end

      assert {:ok, snapshots} = SnapshotReader.list_snapshots(@snapshots_dir)
      assert length(snapshots) == 5

      # Should be sorted by LSN descending (newest first)
      lsns = Enum.map(snapshots, & &1.lsn)
      assert lsns == Enum.sort(lsns, :desc)

      # Verify all snapshot IDs present
      listed_ids = Enum.map(snapshots, & &1.snapshot_id)
      assert Enum.sort(listed_ids) == Enum.sort(snapshot_ids)
    end

    test "snapshot info includes all metadata fields", %{writer: _writer} do
      {:ok, lsn} = WALWriter.append("test data")
      Process.sleep(10)
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      assert {:ok, [snapshot]} = SnapshotReader.list_snapshots(@snapshots_dir)

      assert snapshot.snapshot_id == snapshot_id
      assert snapshot.lsn == lsn
      assert snapshot.entry_count == 1
      assert %DateTime{} = snapshot.created_at
      assert is_integer(snapshot.compressed_size)
      assert is_integer(snapshot.uncompressed_size)
      assert snapshot.compressed_size > 0
      assert snapshot.uncompressed_size > 0
    end

    test "ignores non-snapshot files in directory", %{writer: _writer} do
      # Create snapshot
      {:ok, lsn} = WALWriter.append("test")
      Process.sleep(10)
      {:ok, _snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      # Add non-snapshot files
      File.write!(Path.join(@snapshots_dir, "random.txt"), "random data")
      File.write!(Path.join(@snapshots_dir, "other.dat"), "other data")

      # Should only list snapshot
      assert {:ok, snapshots} = SnapshotReader.list_snapshots(@snapshots_dir)
      assert length(snapshots) == 1
    end

    test "skips corrupt metadata files", %{writer: _writer} do
      # Create valid snapshot
      {:ok, lsn} = WALWriter.append("test")
      Process.sleep(10)
      {:ok, _snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      # Create corrupt metadata file
      corrupt_meta = Path.join(@snapshots_dir, "corrupt_snapshot.meta")
      File.write!(corrupt_meta, "invalid metadata")

      # Should list only valid snapshot
      assert {:ok, snapshots} = SnapshotReader.list_snapshots(@snapshots_dir)
      assert length(snapshots) == 1
    end
  end

  describe "get_snapshot_metadata/2" do
    test "returns metadata for existing snapshot", %{writer: _writer} do
      {:ok, lsn} = WALWriter.append("test data")
      Process.sleep(10)
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      assert {:ok, metadata} = SnapshotReader.get_snapshot_metadata(@snapshots_dir, snapshot_id)

      assert metadata.snapshot_id == snapshot_id
      assert metadata.lsn == lsn
      assert metadata.entry_count == 1
      assert %DateTime{} = metadata.created_at
      assert is_integer(metadata.checksum)
      assert is_integer(metadata.compressed_size)
      assert is_integer(metadata.uncompressed_size)
    end

    test "returns error for non-existent snapshot", %{} do
      assert {:error, _reason} = SnapshotReader.get_snapshot_metadata(@snapshots_dir, "non_existent")
    end

    test "returns error for corrupt metadata", %{writer: _writer} do
      {:ok, lsn} = WALWriter.append("test")
      Process.sleep(10)
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      # Corrupt metadata
      {_data_path, meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, snapshot_id)
      File.write!(meta_path, "corrupted")

      assert {:error, _reason} = SnapshotReader.get_snapshot_metadata(@snapshots_dir, snapshot_id)
    end
  end

  describe "validate_snapshot/2" do
    test "validates correct snapshot", %{writer: _writer} do
      {:ok, lsn} = WALWriter.append("test data")
      Process.sleep(10)
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      assert :ok = SnapshotReader.validate_snapshot(@snapshots_dir, snapshot_id)
    end

    test "detects corrupt data via checksum", %{writer: _writer} do
      {:ok, lsn} = WALWriter.append("test")
      Process.sleep(10)
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      # Corrupt data file
      {data_path, _meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, snapshot_id)
      File.write!(data_path, "corrupted data")

      assert {:error, :corrupt_snapshot} = SnapshotReader.validate_snapshot(@snapshots_dir, snapshot_id)
    end

    test "validates without loading all data", %{writer: _writer} do
      # Create large snapshot
      for i <- 1..1000 do
        {:ok, _lsn} = WALWriter.append(String.duplicate("data #{i} ", 100))
      end

      Process.sleep(10)
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, 999)

      # Validation should be fast (doesn't decompress)
      {time_us, result} = :timer.tc(fn ->
        SnapshotReader.validate_snapshot(@snapshots_dir, snapshot_id)
      end)

      assert result == :ok
      # Should complete in under 1 second
      assert time_us < 1_000_000
    end

    test "returns error for missing data file", %{writer: _writer} do
      {:ok, lsn} = WALWriter.append("test")
      Process.sleep(10)
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      # Delete data file
      {data_path, _meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, snapshot_id)
      File.rm!(data_path)

      assert {:error, _reason} = SnapshotReader.validate_snapshot(@snapshots_dir, snapshot_id)
    end

    test "returns error for missing metadata file", %{writer: _writer} do
      {:ok, lsn} = WALWriter.append("test")
      Process.sleep(10)
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      # Delete metadata file
      {_data_path, meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, snapshot_id)
      File.rm!(meta_path)

      assert {:error, _reason} = SnapshotReader.validate_snapshot(@snapshots_dir, snapshot_id)
    end
  end

  describe "decompression" do
    test "correctly decompresses snapshot data", %{writer: _writer} do
      # Write entries with repetitive data (compresses well)
      test_data = for i <- 1..10, do: String.duplicate("test data #{i} ", 100)

      lsns =
        Enum.map(test_data, fn data ->
          {:ok, lsn} = WALWriter.append(data)
          lsn
        end)

      last_lsn = List.last(lsns)
      Process.sleep(10)

      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, last_lsn)

      # Read and verify
      assert {:ok, entries} = SnapshotReader.read_snapshot(@snapshots_dir, snapshot_id)
      assert length(entries) == 10

      entry_data = Enum.map(entries, & &1.data)
      assert entry_data == test_data
    end

    test "handles large compressed data", %{writer: _writer} do
      # Create large dataset
      for i <- 1..100 do
        {:ok, _lsn} = WALWriter.append(String.duplicate("large data #{i} ", 200))
      end

      Process.sleep(10)
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, 99)

      # Should decompress successfully
      assert {:ok, entries} = SnapshotReader.read_snapshot(@snapshots_dir, snapshot_id)
      assert length(entries) == 100
    end
  end

  describe "concurrent reads" do
    test "handles concurrent snapshot reads", %{writer: _writer} do
      # Create snapshot
      for i <- 1..20 do
        {:ok, _lsn} = WALWriter.append("entry #{i}")
      end

      Process.sleep(10)
      {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, 19)

      # Read concurrently
      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            SnapshotReader.read_snapshot(@snapshots_dir, snapshot_id)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, entries} when length(entries) == 20 -> true
               _ -> false
             end)
    end

    test "handles concurrent list operations", %{writer: _writer} do
      # Create snapshots
      for i <- 1..3 do
        {:ok, _lsn} = WALWriter.append("entry #{i}")
        Process.sleep(10)
        {:ok, _snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, i - 1)
      end

      # List concurrently
      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            SnapshotReader.list_snapshots(@snapshots_dir)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed and return same count
      assert Enum.all?(results, fn
               {:ok, snapshots} when length(snapshots) == 3 -> true
               _ -> false
             end)
    end
  end
end
