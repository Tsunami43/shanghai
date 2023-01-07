defmodule Storage.WAL.SegmentTest do
  use ExUnit.Case, async: false

  alias Storage.WAL.Segment
  alias CoreDomain.Entities.LogEntry
  alias CoreDomain.Types.{LogSequenceNumber, NodeId}

  @test_dir Path.join(System.tmp_dir!(), "shanghai_segment_test_#{:rand.uniform(999_999)}")

  setup do
    # Clean up test directory before each test
    File.rm_rf(@test_dir)
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf(@test_dir)
    end)

    {:ok, test_dir: @test_dir}
  end

  describe "start_link/1 and initialization" do
    test "creates new segment with header", %{test_dir: dir} do
      path = Path.join(dir, "segment_001.wal")

      assert {:ok, pid} =
               Segment.start_link(segment_id: 1, start_lsn: 100, path: path, create: true)

      assert File.exists?(path)

      # Check file size is at least header size (256 bytes)
      {:ok, stat} = File.stat(path)
      assert stat.size == 256

      Segment.close(pid)
    end

    test "validates header on existing segment", %{test_dir: dir} do
      path = Path.join(dir, "segment_002.wal")

      # Create segment first
      {:ok, pid} = Segment.start_link(segment_id: 2, start_lsn: 200, path: path, create: true)
      Segment.close(pid)

      # Open existing segment
      assert {:ok, pid2} =
               Segment.start_link(segment_id: 2, start_lsn: 200, path: path, create: false)

      {:ok, info} = Segment.info(pid2)
      assert info.segment_id == 2
      assert info.start_lsn == 200

      Segment.close(pid2)
    end

    test "rejects mismatched segment ID", %{test_dir: dir} do
      path = Path.join(dir, "segment_003.wal")

      # Create with ID 3
      {:ok, pid} = Segment.start_link(segment_id: 3, start_lsn: 300, path: path, create: true)
      Segment.close(pid)

      # Try to open with wrong ID - should fail during init
      Process.flag(:trap_exit, true)
      result = Segment.start_link(segment_id: 999, start_lsn: 300, path: path, create: false)

      case result do
        {:error, {:segment_mismatch, 3, 300}} -> assert true
        {:ok, pid} ->
          receive do
            {:EXIT, ^pid, {:segment_mismatch, 3, 300}} -> assert true
          after
            100 -> flunk("Expected process to exit with segment_mismatch")
          end
        other -> flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "creates parent directories if needed", %{test_dir: dir} do
      nested_path = Path.join([dir, "wal", "segments", "segment_004.wal"])

      assert {:ok, pid} =
               Segment.start_link(segment_id: 4, start_lsn: 400, path: nested_path, create: true)

      assert File.exists?(nested_path)
      Segment.close(pid)
    end
  end

  describe "append_entry/2" do
    test "appends entry and returns offset", %{test_dir: dir} do
      path = Path.join(dir, "segment_005.wal")
      {:ok, pid} = Segment.start_link(segment_id: 5, start_lsn: 500, path: path)

      entry = LogEntry.new(
        LogSequenceNumber.new(500),
        "test data",
        %NodeId{value: "node1"},
        %{}
      )

      assert {:ok, offset} = Segment.append_entry(pid, entry)
      assert offset == 256

      Segment.close(pid)
    end

    test "appends multiple entries with increasing offsets", %{test_dir: dir} do
      path = Path.join(dir, "segment_006.wal")
      {:ok, pid} = Segment.start_link(segment_id: 6, start_lsn: 600, path: path)

      entry1 = LogEntry.new(LogSequenceNumber.new(600), "first", %NodeId{value: "node1"}, %{})

      entry2 = LogEntry.new(LogSequenceNumber.new(601), "second", %NodeId{value: "node1"}, %{})

      entry3 = LogEntry.new(LogSequenceNumber.new(602), "third", %NodeId{value: "node1"}, %{})

      {:ok, offset1} = Segment.append_entry(pid, entry1)
      {:ok, offset2} = Segment.append_entry(pid, entry2)
      {:ok, offset3} = Segment.append_entry(pid, entry3)

      assert offset1 == 256
      assert offset2 > offset1
      assert offset3 > offset2

      {:ok, info} = Segment.info(pid)
      assert info.entry_count == 3

      Segment.close(pid)
    end

    test "syncs data to disk after append", %{test_dir: dir} do
      path = Path.join(dir, "segment_007.wal")
      {:ok, pid} = Segment.start_link(segment_id: 7, start_lsn: 700, path: path)

      entry = LogEntry.new(LogSequenceNumber.new(700), "sync test", %NodeId{value: "node1"}, %{})

      {:ok, _offset} = Segment.append_entry(pid, entry)

      # File should be synced and readable
      {:ok, stat} = File.stat(path)
      assert stat.size > 256

      Segment.close(pid)
    end

    test "appends large entry", %{test_dir: dir} do
      path = Path.join(dir, "segment_008.wal")
      {:ok, pid} = Segment.start_link(segment_id: 8, start_lsn: 800, path: path)

      large_data = String.duplicate("x", 100_000)

      entry = LogEntry.new(
        LogSequenceNumber.new(800),
        large_data,
        %NodeId{value: "node1"},
        %{}
      )

      assert {:ok, offset} = Segment.append_entry(pid, entry)
      assert offset == 256

      {:ok, info} = Segment.info(pid)
      assert info.entry_count == 1

      Segment.close(pid)
    end
  end

  describe "read_entry/2" do
    test "reads appended entry", %{test_dir: dir} do
      path = Path.join(dir, "segment_009.wal")
      {:ok, pid} = Segment.start_link(segment_id: 9, start_lsn: 900, path: path)

      entry = LogEntry.new(
        LogSequenceNumber.new(900),
        "readable data",
        %NodeId{value: "node1"},
        %{key: "value"}
      )

      {:ok, offset} = Segment.append_entry(pid, entry)
      assert {:ok, read_entry} = Segment.read_entry(pid, offset)

      assert read_entry.lsn == entry.lsn
      assert read_entry.data == entry.data
      assert read_entry.node_id == entry.node_id
      assert read_entry.metadata == entry.metadata

      Segment.close(pid)
    end

    test "reads multiple entries", %{test_dir: dir} do
      path = Path.join(dir, "segment_010.wal")
      {:ok, pid} = Segment.start_link(segment_id: 10, start_lsn: 1000, path: path)

      entries = [
        LogEntry.new(LogSequenceNumber.new(1000), "entry 1", %NodeId{value: "node1"}, %{}),
        LogEntry.new(LogSequenceNumber.new(1001), "entry 2", %NodeId{value: "node1"}, %{}),
        LogEntry.new(LogSequenceNumber.new(1002), "entry 3", %NodeId{value: "node1"}, %{})
      ]

      offsets =
        Enum.map(entries, fn entry ->
          {:ok, offset} = Segment.append_entry(pid, entry)
          offset
        end)

      # Read all entries back
      read_entries =
        Enum.map(offsets, fn offset ->
          {:ok, entry} = Segment.read_entry(pid, offset)
          entry
        end)

      assert Enum.map(read_entries, & &1.lsn.value) == [1000, 1001, 1002]
      assert Enum.map(read_entries, & &1.data) == ["entry 1", "entry 2", "entry 3"]

      Segment.close(pid)
    end

    test "returns error for invalid offset", %{test_dir: dir} do
      path = Path.join(dir, "segment_011.wal")
      {:ok, pid} = Segment.start_link(segment_id: 11, start_lsn: 1100, path: path)

      assert {:error, :offset_out_of_bounds} = Segment.read_entry(pid, 9999)

      Segment.close(pid)
    end

    test "detects corrupted entry checksum", %{test_dir: dir} do
      path = Path.join(dir, "segment_012.wal")
      {:ok, pid} = Segment.start_link(segment_id: 12, start_lsn: 1200, path: path)

      entry = LogEntry.new(
        LogSequenceNumber.new(1200),
        "corrupt me",
        %NodeId{value: "node1"},
        %{}
      )

      {:ok, offset} = Segment.append_entry(pid, entry)

      # Close segment to modify file
      Segment.close(pid)

      # Corrupt the data in the file (skip header + entry header, corrupt payload)
      {:ok, file} = File.open(path, [:read, :write, :binary])
      :file.pwrite(file, offset + 16, "CORRUPTED")
      File.close(file)

      # Reopen and try to read
      {:ok, pid2} =
        Segment.start_link(segment_id: 12, start_lsn: 1200, path: path, create: false)

      assert {:error, :entry_checksum_mismatch} = Segment.read_entry(pid2, offset)

      Segment.close(pid2)
    end
  end

  describe "seal/1" do
    test "seals segment successfully", %{test_dir: dir} do
      path = Path.join(dir, "segment_013.wal")
      {:ok, pid} = Segment.start_link(segment_id: 13, start_lsn: 1300, path: path)

      entry = LogEntry.new(
        LogSequenceNumber.new(1300),
        "before seal",
        %NodeId{value: "node1"},
        %{}
      )

      {:ok, _offset} = Segment.append_entry(pid, entry)

      assert :ok = Segment.seal(pid)

      {:ok, info} = Segment.info(pid)
      assert info.sealed == true

      Segment.close(pid)
    end

    test "rejects appends after seal", %{test_dir: dir} do
      path = Path.join(dir, "segment_014.wal")
      {:ok, pid} = Segment.start_link(segment_id: 14, start_lsn: 1400, path: path)

      :ok = Segment.seal(pid)

      entry = LogEntry.new(
        LogSequenceNumber.new(1400),
        "after seal",
        %NodeId{value: "node1"},
        %{}
      )

      assert {:error, :segment_sealed} = Segment.append_entry(pid, entry)

      Segment.close(pid)
    end

    test "allows reads after seal", %{test_dir: dir} do
      path = Path.join(dir, "segment_015.wal")
      {:ok, pid} = Segment.start_link(segment_id: 15, start_lsn: 1500, path: path)

      entry = LogEntry.new(
        LogSequenceNumber.new(1500),
        "sealed read",
        %NodeId{value: "node1"},
        %{}
      )

      {:ok, offset} = Segment.append_entry(pid, entry)
      :ok = Segment.seal(pid)

      assert {:ok, read_entry} = Segment.read_entry(pid, offset)
      assert read_entry.data == "sealed read"

      Segment.close(pid)
    end

    test "seal is idempotent", %{test_dir: dir} do
      path = Path.join(dir, "segment_016.wal")
      {:ok, pid} = Segment.start_link(segment_id: 16, start_lsn: 1600, path: path)

      assert :ok = Segment.seal(pid)
      assert :ok = Segment.seal(pid)
      assert :ok = Segment.seal(pid)

      {:ok, info} = Segment.info(pid)
      assert info.sealed == true

      Segment.close(pid)
    end
  end

  describe "info/1" do
    test "returns segment information", %{test_dir: dir} do
      path = Path.join(dir, "segment_017.wal")
      {:ok, pid} = Segment.start_link(segment_id: 17, start_lsn: 1700, path: path)

      {:ok, info} = Segment.info(pid)

      assert info.segment_id == 17
      assert info.start_lsn == 1700
      assert info.path == path
      assert info.sealed == false
      assert info.entry_count == 0
      assert info.current_offset == 256

      Segment.close(pid)
    end

    test "tracks entry count", %{test_dir: dir} do
      path = Path.join(dir, "segment_018.wal")
      {:ok, pid} = Segment.start_link(segment_id: 18, start_lsn: 1800, path: path)

      for i <- 1..5 do
        entry = LogEntry.new(
          LogSequenceNumber.new(1800 + i - 1),
          "entry #{i}",
          %NodeId{value: "node1"},
          %{}
        )

        Segment.append_entry(pid, entry)
      end

      {:ok, info} = Segment.info(pid)
      assert info.entry_count == 5

      Segment.close(pid)
    end
  end

  describe "close/1" do
    test "closes segment cleanly", %{test_dir: dir} do
      path = Path.join(dir, "segment_019.wal")
      {:ok, pid} = Segment.start_link(segment_id: 19, start_lsn: 1900, path: path)

      entry = LogEntry.new(
        LogSequenceNumber.new(1900),
        "close test",
        %NodeId{value: "node1"},
        %{}
      )

      {:ok, _offset} = Segment.append_entry(pid, entry)

      assert :ok = Segment.close(pid)

      # Verify file was closed and data persisted
      assert File.exists?(path)
      {:ok, stat} = File.stat(path)
      assert stat.size > 256
    end
  end

  describe "persistence and recovery" do
    test "data survives process restart", %{test_dir: dir} do
      path = Path.join(dir, "segment_020.wal")

      # First process: write data
      {:ok, pid1} = Segment.start_link(segment_id: 20, start_lsn: 2000, path: path)

      entries = [
        LogEntry.new(LogSequenceNumber.new(2000), "persist 1", %NodeId{value: "node1"}, %{}),
        LogEntry.new(LogSequenceNumber.new(2001), "persist 2", %NodeId{value: "node1"}, %{})
      ]

      offsets =
        Enum.map(entries, fn entry ->
          {:ok, offset} = Segment.append_entry(pid1, entry)
          offset
        end)

      Segment.close(pid1)

      # Second process: read data
      {:ok, pid2} =
        Segment.start_link(segment_id: 20, start_lsn: 2000, path: path, create: false)

      read_entries =
        Enum.map(offsets, fn offset ->
          {:ok, entry} = Segment.read_entry(pid2, offset)
          entry
        end)

      assert Enum.map(read_entries, & &1.data) == ["persist 1", "persist 2"]

      Segment.close(pid2)
    end
  end

  describe "error handling" do
    test "handles invalid path", %{test_dir: _dir} do
      # Try to create segment in non-writable location (root usually)
      Process.flag(:trap_exit, true)

      result =
        Segment.start_link(
          segment_id: 99,
          start_lsn: 9900,
          path: "/invalid/nonexistent/segment.wal"
        )

      case result do
        {:error, _reason} -> assert true
        {:ok, pid} ->
          receive do
            {:EXIT, ^pid, _reason} -> assert true
          after
            100 -> flunk("Expected process to exit with error")
          end
      end
    end

    test "handles corrupted header", %{test_dir: dir} do
      path = Path.join(dir, "corrupt_header.wal")

      # Write garbage header
      File.write!(path, String.duplicate("GARBAGE", 50))

      Process.flag(:trap_exit, true)
      result = Segment.start_link(segment_id: 21, start_lsn: 2100, path: path, create: false)

      case result do
        {:error, _reason} -> assert true
        {:ok, pid} ->
          receive do
            {:EXIT, ^pid, _reason} -> assert true
          after
            100 -> flunk("Expected process to exit with error")
          end
      end
    end
  end
end
