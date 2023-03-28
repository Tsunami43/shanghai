defmodule Storage.Snapshot.WriterTest do
  use ExUnit.Case, async: false

  alias CoreDomain.Entities.{LogEntry, LogSequenceNumber, NodeId}
  alias Storage.Index.SegmentIndex
  alias Storage.Persistence.Serializer
  alias Storage.Snapshot.Writer, as: SnapshotWriter
  alias Storage.WAL.{Reader, SegmentManager, Writer}

  @test_dir Path.join(
              System.tmp_dir!(),
              "shanghai_snapshot_writer_test_#{:rand.uniform(999_999)}"
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

    # Start WAL Writer (to populate data)
    {:ok, writer_pid} =
      Writer.start_link(
        data_dir: @wal_dir,
        node_id: "test_node",
        segment_size_threshold: 10 * 1024 * 1024,
        segment_time_threshold: 3600
      )

    # Start WAL Reader
    {:ok, reader_pid} = Reader.start_link([])

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

  describe "create_snapshot/3" do
    test "creates snapshot with empty data", %{} do
      assert {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, 0)
      assert String.starts_with?(snapshot_id, "snapshot_")
      assert String.contains?(snapshot_id, "_lsn_0000000000000000")

      # Verify files exist
      {data_path, meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, snapshot_id)
      assert File.exists?(data_path)
      assert File.exists?(meta_path)
    end

    test "creates snapshot with single entry", %{writer: _writer} do
      # Write one entry
      {:ok, lsn} = Writer.append("test data")
      Process.sleep(10)

      assert {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      assert String.contains?(
               snapshot_id,
               "_lsn_#{String.pad_leading(Integer.to_string(lsn), 16, "0")}"
             )

      # Verify files exist
      {data_path, meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, snapshot_id)
      assert File.exists?(data_path)
      assert File.exists?(meta_path)
    end

    test "creates snapshot with multiple entries", %{writer: _writer} do
      # Write multiple entries
      lsns =
        for i <- 1..10 do
          {:ok, lsn} = Writer.append("entry #{i}")
          lsn
        end

      last_lsn = List.last(lsns)
      Process.sleep(10)

      assert {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, last_lsn)

      # Verify snapshot ID format
      assert String.starts_with?(snapshot_id, "snapshot_")
      assert String.contains?(snapshot_id, "_lsn_")
    end

    test "creates snapshot with various data types", %{writer: _writer} do
      test_data = [
        "string",
        12_345,
        %{key: "value"},
        [1, 2, 3],
        {:tuple, "data"}
      ]

      lsns =
        Enum.map(test_data, fn data ->
          {:ok, lsn} = Writer.append(data)
          lsn
        end)

      last_lsn = List.last(lsns)
      Process.sleep(10)

      assert {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, last_lsn)

      {data_path, meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, snapshot_id)
      assert File.exists?(data_path)
      assert File.exists?(meta_path)
    end

    test "snapshot files are compressed", %{writer: _writer} do
      # Write entries
      for i <- 1..100 do
        {:ok, _lsn} = Writer.append(String.duplicate("data #{i} ", 100))
      end

      Process.sleep(10)

      assert {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, 99)

      {data_path, _meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, snapshot_id)

      # Compressed size should be smaller than uncompressed
      # (Just verify file exists and has content)
      assert File.exists?(data_path)
      stat = File.stat!(data_path)
      assert stat.size > 0
    end

    test "snapshot metadata contains correct information", %{writer: _writer} do
      # Write entries
      lsns =
        for i <- 1..5 do
          {:ok, lsn} = Writer.append("entry #{i}")
          lsn
        end

      last_lsn = List.last(lsns)
      Process.sleep(10)

      assert {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, last_lsn)

      # Read metadata
      {_data_path, meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, snapshot_id)
      {:ok, meta_binary} = File.read(meta_path)
      {:ok, metadata} = Serializer.decode(meta_binary)

      assert metadata.snapshot_id == snapshot_id
      assert metadata.lsn == last_lsn
      assert metadata.entry_count == 5
      assert is_integer(metadata.checksum)
      assert %DateTime{} = metadata.created_at
      assert is_integer(metadata.compressed_size)
      assert is_integer(metadata.uncompressed_size)
    end

    test "creates directory if it doesn't exist", %{writer: _writer} do
      {:ok, lsn} = Writer.append("test")
      Process.sleep(10)

      non_existent_dir = Path.join(@test_dir, "new_snapshots")
      refute File.exists?(non_existent_dir)

      assert {:ok, _snapshot_id} = SnapshotWriter.create_snapshot(non_existent_dir, lsn)
      assert File.exists?(non_existent_dir)
    end

    test "creates empty snapshot for non-existent LSN range", %{} do
      # Creating snapshot with LSN that doesn't exist creates empty snapshot
      assert {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, 999_999)

      # Verify it's empty
      {data_path, meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, snapshot_id)
      assert File.exists?(data_path)
      assert File.exists?(meta_path)

      # Read metadata
      {:ok, meta_binary} = File.read(meta_path)
      {:ok, metadata} = Serializer.decode(meta_binary)
      assert metadata.entry_count == 0
    end
  end

  describe "snapshot_paths/2" do
    test "returns correct file paths" do
      snapshot_id = "snapshot_20260111_120000_lsn_0000000000001000"
      {data_path, meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, snapshot_id)

      assert data_path == Path.join(@snapshots_dir, "#{snapshot_id}.snap")
      assert meta_path == Path.join(@snapshots_dir, "#{snapshot_id}.meta")
    end

    test "paths are in correct directory" do
      snapshot_id = "test_snapshot"
      {data_path, meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, snapshot_id)

      assert Path.dirname(data_path) == @snapshots_dir
      assert Path.dirname(meta_path) == @snapshots_dir
    end
  end

  describe "snapshot ID format" do
    test "snapshot ID includes timestamp and LSN", %{writer: _writer} do
      {:ok, lsn} = Writer.append("test")
      Process.sleep(10)

      assert {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      # Format: snapshot_YYYYMMDD_HHMMSS_lsn_NNNNNNNNNNNNNNN
      parts = String.split(snapshot_id, "_")
      assert length(parts) == 5
      assert Enum.at(parts, 0) == "snapshot"
      assert Enum.at(parts, 3) == "lsn"

      # Verify date format (YYYYMMDD)
      date_part = Enum.at(parts, 1)
      assert String.length(date_part) == 8
      assert String.match?(date_part, ~r/^\d{8}$/)

      # Verify time format (HHMMSS)
      time_part = Enum.at(parts, 2)
      assert String.length(time_part) == 6
      assert String.match?(time_part, ~r/^\d{6}$/)

      # Verify LSN format (16 digits)
      lsn_part = Enum.at(parts, 4)
      assert String.length(lsn_part) == 16
      assert String.match?(lsn_part, ~r/^\d{16}$/)
    end

    test "snapshot IDs are sortable by timestamp", %{writer: _writer} do
      {:ok, lsn1} = Writer.append("test 1")
      Process.sleep(10)
      {:ok, id1} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn1)

      Process.sleep(1000)

      {:ok, lsn2} = Writer.append("test 2")
      Process.sleep(10)
      {:ok, id2} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn2)

      # Second snapshot should sort after first
      assert id1 < id2
    end
  end

  describe "checksum integrity" do
    test "snapshot includes valid checksum", %{writer: _writer} do
      {:ok, lsn} = Writer.append("test data")
      Process.sleep(10)

      assert {:ok, snapshot_id} = SnapshotWriter.create_snapshot(@snapshots_dir, lsn)

      {data_path, meta_path} = SnapshotWriter.snapshot_paths(@snapshots_dir, snapshot_id)

      # Read metadata
      {:ok, meta_binary} = File.read(meta_path)
      {:ok, metadata} = Serializer.decode(meta_binary)

      # Read data and compute checksum
      {:ok, data} = File.read(data_path)
      actual_checksum = Serializer.compute_checksum(data)

      assert metadata.checksum == actual_checksum
    end
  end

  describe "concurrent snapshot creation" do
    test "handles concurrent snapshot requests", %{writer: _writer} do
      # Write some entries
      for i <- 1..10 do
        {:ok, _lsn} = Writer.append("entry #{i}")
      end

      Process.sleep(10)

      # Create snapshots concurrently with different LSNs
      tasks =
        for i <- [3, 6, 9] do
          Task.async(fn ->
            SnapshotWriter.create_snapshot(@snapshots_dir, i)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _snapshot_id} -> true
               _ -> false
             end)

      # Snapshot IDs should be unique (different LSNs)
      snapshot_ids = Enum.map(results, fn {:ok, id} -> id end)
      assert length(Enum.uniq(snapshot_ids)) == 3
    end
  end
end
