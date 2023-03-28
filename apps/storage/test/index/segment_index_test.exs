defmodule Storage.Index.SegmentIndexTest do
  use ExUnit.Case, async: false

  alias Storage.Index.SegmentIndex

  @test_dir Path.join(System.tmp_dir!(), "shanghai_index_test_#{:rand.uniform(999_999)}")

  setup do
    # Clean up test directory before each test
    File.rm_rf(@test_dir)
    File.mkdir_p!(@test_dir)

    # Start SegmentIndex for tests
    {:ok, pid} = SegmentIndex.start_link(data_dir: @test_dir)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(@test_dir)
    end)

    {:ok, index: pid, test_dir: @test_dir}
  end

  describe "insert/4 and lookup/2" do
    test "inserts and retrieves index entry", %{index: pid} do
      assert :ok = SegmentIndex.insert(pid, 100, 1, 256)
      assert {:ok, {1, 256}} = SegmentIndex.lookup(pid, 100)
    end

    test "inserts multiple entries", %{index: pid} do
      assert :ok = SegmentIndex.insert(pid, 100, 1, 256)
      assert :ok = SegmentIndex.insert(pid, 101, 1, 512)
      assert :ok = SegmentIndex.insert(pid, 200, 2, 256)

      assert {:ok, {1, 256}} = SegmentIndex.lookup(pid, 100)
      assert {:ok, {1, 512}} = SegmentIndex.lookup(pid, 101)
      assert {:ok, {2, 256}} = SegmentIndex.lookup(pid, 200)
    end

    test "returns error for non-existent LSN", %{index: pid} do
      assert {:error, :not_found} = SegmentIndex.lookup(pid, 999)
    end

    test "updates existing LSN", %{index: pid} do
      assert :ok = SegmentIndex.insert(pid, 100, 1, 256)
      assert {:ok, {1, 256}} = SegmentIndex.lookup(pid, 100)

      # Update with new location
      assert :ok = SegmentIndex.insert(pid, 100, 2, 512)
      assert {:ok, {2, 512}} = SegmentIndex.lookup(pid, 100)
    end

    test "handles large LSN values", %{index: pid} do
      large_lsn = 9_999_999_999_999

      assert :ok = SegmentIndex.insert(pid, large_lsn, 100, 1024)
      assert {:ok, {100, 1024}} = SegmentIndex.lookup(pid, large_lsn)
    end
  end

  describe "flush/1" do
    test "flushes index to disk", %{index: pid, test_dir: dir} do
      SegmentIndex.insert(pid, 100, 1, 256)
      SegmentIndex.insert(pid, 101, 1, 512)

      assert :ok = SegmentIndex.flush(pid)

      # Verify files exist
      index_path = Path.join(dir, "segment_index.dat")
      backup_path = Path.join(dir, "segment_index.backup.dat")

      assert File.exists?(index_path)
      assert File.exists?(backup_path)
    end

    test "auto-flushes after threshold", %{index: pid, test_dir: dir} do
      # Insert more than threshold (default 1000)
      for i <- 1..1001 do
        SegmentIndex.insert(pid, i, 1, i * 256)
      end

      # Give it a moment to flush
      Process.sleep(100)

      # Check that files were created
      index_path = Path.join(dir, "segment_index.dat")
      assert File.exists?(index_path)
    end
  end

  describe "stats/1" do
    test "returns index statistics", %{index: pid} do
      SegmentIndex.insert(pid, 100, 1, 256)
      SegmentIndex.insert(pid, 101, 1, 512)

      assert {:ok, stats} = SegmentIndex.stats(pid)
      assert stats.entry_count == 2
      assert stats.insert_count == 2
      assert is_integer(stats.last_flush)
    end

    test "resets insert count after flush", %{index: pid} do
      SegmentIndex.insert(pid, 100, 1, 256)
      SegmentIndex.insert(pid, 101, 1, 512)

      {:ok, stats_before} = SegmentIndex.stats(pid)
      assert stats_before.insert_count == 2

      :ok = SegmentIndex.flush(pid)

      {:ok, stats_after} = SegmentIndex.stats(pid)
      assert stats_after.insert_count == 0
      assert stats_after.entry_count == 2
    end
  end

  describe "delete_segment/2" do
    test "deletes all entries for a segment", %{index: pid} do
      # Insert entries for multiple segments
      SegmentIndex.insert(pid, 100, 1, 256)
      SegmentIndex.insert(pid, 101, 1, 512)
      SegmentIndex.insert(pid, 200, 2, 256)
      SegmentIndex.insert(pid, 201, 2, 512)

      {:ok, stats_before} = SegmentIndex.stats(pid)
      assert stats_before.entry_count == 4

      # Delete segment 1
      assert :ok = SegmentIndex.delete_segment(pid, 1)

      # Verify segment 1 entries are gone
      assert {:error, :not_found} = SegmentIndex.lookup(pid, 100)
      assert {:error, :not_found} = SegmentIndex.lookup(pid, 101)

      # Verify segment 2 entries still exist
      assert {:ok, {2, 256}} = SegmentIndex.lookup(pid, 200)
      assert {:ok, {2, 512}} = SegmentIndex.lookup(pid, 201)

      {:ok, stats_after} = SegmentIndex.stats(pid)
      assert stats_after.entry_count == 2
    end

    test "handles deleting non-existent segment", %{index: pid} do
      assert :ok = SegmentIndex.delete_segment(pid, 999)
    end
  end

  describe "persistence and recovery" do
    test "loads index from disk on startup", %{index: existing_pid, test_dir: dir} do
      # Stop existing process from setup
      GenServer.stop(existing_pid)

      # Create and populate first index
      {:ok, pid1} = SegmentIndex.start_link(data_dir: dir)

      SegmentIndex.insert(pid1, 100, 1, 256)
      SegmentIndex.insert(pid1, 101, 1, 512)
      SegmentIndex.insert(pid1, 200, 2, 256)

      SegmentIndex.flush(pid1)
      GenServer.stop(pid1)

      # Start new index from same directory
      {:ok, pid2} = SegmentIndex.start_link(data_dir: dir)

      # Verify data was loaded
      assert {:ok, {1, 256}} = SegmentIndex.lookup(pid2, 100)
      assert {:ok, {1, 512}} = SegmentIndex.lookup(pid2, 101)
      assert {:ok, {2, 256}} = SegmentIndex.lookup(pid2, 200)

      {:ok, stats} = SegmentIndex.stats(pid2)
      assert stats.entry_count == 3

      GenServer.stop(pid2)
    end

    test "loads from backup if primary is corrupted", %{index: existing_pid, test_dir: dir} do
      # Stop existing process from setup
      GenServer.stop(existing_pid)

      # Create and populate index
      {:ok, pid1} = SegmentIndex.start_link(data_dir: dir)

      SegmentIndex.insert(pid1, 100, 1, 256)
      SegmentIndex.insert(pid1, 101, 1, 512)

      SegmentIndex.flush(pid1)
      GenServer.stop(pid1)

      # Corrupt primary index file
      index_path = Path.join(dir, "segment_index.dat")
      File.write!(index_path, "CORRUPTED DATA")

      # Start new index - should load from backup
      {:ok, pid2} = SegmentIndex.start_link(data_dir: dir)

      # Verify data was loaded from backup
      assert {:ok, {1, 256}} = SegmentIndex.lookup(pid2, 100)
      assert {:ok, {1, 512}} = SegmentIndex.lookup(pid2, 101)

      GenServer.stop(pid2)
    end

    test "starts fresh if no index files exist", %{index: existing_pid, test_dir: dir} do
      # Stop existing process from setup
      GenServer.stop(existing_pid)

      # Ensure directory is empty
      File.rm_rf!(dir)
      File.mkdir_p!(dir)

      {:ok, pid} = SegmentIndex.start_link(data_dir: dir)

      {:ok, stats} = SegmentIndex.stats(pid)
      assert stats.entry_count == 0

      GenServer.stop(pid)
    end
  end

  describe "rebuild_from_segments/2" do
    setup %{test_dir: dir} do
      segments_dir = Path.join(dir, "segments")
      File.mkdir_p!(segments_dir)

      {:ok, segments_dir: segments_dir}
    end

    test "rebuilds index by scanning segment files", %{index: pid, segments_dir: segments_dir} do
      # Create mock segment files with proper format
      create_mock_segment(segments_dir, "segment_0000000000000001.wal", [
        {100, "entry 1"},
        {101, "entry 2"}
      ])

      create_mock_segment(segments_dir, "segment_0000000000000002.wal", [
        {200, "entry 3"},
        {201, "entry 4"}
      ])

      # Rebuild index
      assert {:ok, count} = SegmentIndex.rebuild_from_segments(pid, segments_dir)
      assert count == 4

      # Verify entries
      assert {:ok, {1, 256}} = SegmentIndex.lookup(pid, 100)
      assert {:ok, {2, 256}} = SegmentIndex.lookup(pid, 200)

      {:ok, stats} = SegmentIndex.stats(pid)
      assert stats.entry_count == 4
    end

    test "handles empty segments directory", %{index: pid, segments_dir: segments_dir} do
      # No segment files

      assert {:ok, 0} = SegmentIndex.rebuild_from_segments(pid, segments_dir)

      {:ok, stats} = SegmentIndex.stats(pid)
      assert stats.entry_count == 0
    end

    test "skips invalid segment files", %{index: pid, segments_dir: segments_dir} do
      # Create one valid segment
      create_mock_segment(segments_dir, "segment_0000000000000001.wal", [{100, "entry 1"}])

      # Create invalid file (wrong naming pattern)
      invalid_path = Path.join(segments_dir, "invalid.wal")
      File.write!(invalid_path, "garbage")

      # Should process only valid segment
      assert {:ok, count} = SegmentIndex.rebuild_from_segments(pid, segments_dir)
      assert count == 1
    end
  end

  describe "concurrent access" do
    test "handles concurrent inserts", %{index: pid} do
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            SegmentIndex.insert(pid, i, 1, i * 256)
          end)
        end

      Enum.each(tasks, &Task.await/1)

      {:ok, stats} = SegmentIndex.stats(pid)
      assert stats.entry_count == 100
    end

    test "handles concurrent reads", %{index: pid} do
      # Insert entries
      for i <- 1..50 do
        SegmentIndex.insert(pid, i, 1, i * 256)
      end

      # Concurrent reads
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            SegmentIndex.lookup(pid, i)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)
    end
  end

  ## Helper Functions

  @spec create_mock_segment(String.t(), String.t(), [{non_neg_integer(), String.t()}]) :: :ok
  defp create_mock_segment(dir, filename, entries) do
    path = Path.join(dir, filename)

    # Write header (256 bytes)
    header = String.duplicate(<<0>>, 256)

    # Write entries
    entry_data =
      Enum.map_join(entries, "", fn {lsn, data} ->
        # Serialize the entry data
        payload = :erlang.term_to_binary(%{lsn: lsn, data: data}, [:compressed])
        length = byte_size(payload)
        checksum = :erlang.crc32(payload)

        <<length::32, lsn::64, checksum::32, payload::binary>>
      end)

    File.write!(path, header <> entry_data)

    :ok
  end
end
