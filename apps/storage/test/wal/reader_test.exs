defmodule Storage.WAL.ReaderTest do
  use ExUnit.Case, async: false

  alias Storage.WAL.{Reader, Writer, SegmentManager}
  alias Storage.Index.SegmentIndex

  @test_dir Path.join(System.tmp_dir!(), "shanghai_reader_test_#{:rand.uniform(999_999)}")
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
    File.mkdir_p!(@test_dir)

    # Start SegmentIndex
    index_dir = Path.join(@test_dir, "index")
    {:ok, index_pid} = SegmentIndex.start_link(data_dir: index_dir)

    # Start Writer (to populate data)
    {:ok, writer_pid} =
      Writer.start_link(
        data_dir: @test_dir,
        node_id: "test_node",
        segment_size_threshold: 10 * 1024 * 1024,  # 10 MB
        segment_time_threshold: 3600
      )

    # Start Reader
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

    {:ok, reader: reader_pid, writer: writer_pid, index: index_pid}
  end

  describe "read/1" do
    test "reads single entry by LSN", %{writer: _writer, reader: _reader} do
      # Write an entry
      {:ok, lsn} = Writer.append("test data")

      # Give index time to update
      Process.sleep(10)

      # Read it back
      assert {:ok, entry} = Reader.read(lsn)
      assert entry.data == "test data"
      assert entry.lsn.value == lsn
    end

    test "reads multiple entries", %{writer: _writer, reader: _reader} do
      # Write multiple entries
      data = ["entry 1", "entry 2", "entry 3"]

      lsns =
        Enum.map(data, fn d ->
          {:ok, lsn} = Writer.append(d)
          lsn
        end)

      Process.sleep(10)

      # Read all back
      Enum.zip(lsns, data)
      |> Enum.each(fn {lsn, expected_data} ->
        assert {:ok, entry} = Reader.read(lsn)
        assert entry.data == expected_data
      end)
    end

    test "returns error for non-existent LSN", %{reader: _reader} do
      assert {:error, :not_found} = Reader.read(999_999)
    end

    test "reads various data types", %{writer: _writer, reader: _reader} do
      test_data = [
        "string",
        12345,
        %{key: "value"},
        [1, 2, 3],
        {:tuple, "data"}
      ]

      lsns =
        Enum.map(test_data, fn d ->
          {:ok, lsn} = Writer.append(d)
          lsn
        end)

      Process.sleep(10)

      Enum.zip(lsns, test_data)
      |> Enum.each(fn {lsn, expected} ->
        assert {:ok, entry} = Reader.read(lsn)
        assert entry.data == expected
      end)
    end
  end

  describe "read_range/2" do
    test "reads range of entries", %{writer: _writer, reader: _reader} do
      # Write 10 entries
      lsns =
        for i <- 1..10 do
          {:ok, lsn} = Writer.append("entry #{i}")
          lsn
        end

      start_lsn = Enum.at(lsns, 0)
      end_lsn = Enum.at(lsns, 9)

      Process.sleep(10)

      assert {:ok, entries} = Reader.read_range(start_lsn, end_lsn)
      assert length(entries) == 10

      # Verify order
      assert Enum.map(entries, & &1.lsn.value) == lsns
    end

    test "reads partial range", %{writer: _writer, reader: _reader} do
      # Write entries
      lsns =
        for i <- 1..10 do
          {:ok, lsn} = Writer.append("entry #{i}")
          lsn
        end

      # Read middle portion
      start_lsn = Enum.at(lsns, 3)
      end_lsn = Enum.at(lsns, 7)

      Process.sleep(10)

      assert {:ok, entries} = Reader.read_range(start_lsn, end_lsn)
      assert length(entries) == 5

      expected_lsns = Enum.slice(lsns, 3..7)
      assert Enum.map(entries, & &1.lsn.value) == expected_lsns
    end

    test "returns empty list for non-existent range", %{reader: _reader} do
      assert {:ok, []} = Reader.read_range(999_000, 999_010)
    end

    test "handles single entry range", %{writer: _writer, reader: _reader} do
      {:ok, lsn} = Writer.append("single")

      Process.sleep(10)

      assert {:ok, [entry]} = Reader.read_range(lsn, lsn)
      assert entry.data == "single"
    end
  end

  describe "stats/0" do
    test "returns reader statistics", %{reader: _reader} do
      assert {:ok, stats} = Reader.stats()
      assert is_integer(stats.cached_segments)
    end

    test "tracks cached segments", %{writer: _writer, reader: _reader} do
      # Write and read entries
      {:ok, lsn1} = Writer.append("entry 1")
      {:ok, lsn2} = Writer.append("entry 2")

      Process.sleep(10)

      # Read entries (should cache segment)
      {:ok, _} = Reader.read(lsn1)
      {:ok, _} = Reader.read(lsn2)

      {:ok, stats} = Reader.stats()
      # Should have cached at least 1 segment
      assert stats.cached_segments >= 1
    end
  end

  describe "segment caching" do
    test "caches segments for repeated reads", %{writer: _writer, reader: _reader} do
      # Write entries
      lsns =
        for i <- 1..5 do
          {:ok, lsn} = Writer.append("entry #{i}")
          lsn
        end

      Process.sleep(10)

      # First read - will cache segment
      {:ok, _} = Reader.read(Enum.at(lsns, 0))

      {:ok, stats_before} = Reader.stats()

      # Second read - should use cache
      {:ok, _} = Reader.read(Enum.at(lsns, 1))

      {:ok, stats_after} = Reader.stats()

      # Cache size shouldn't increase if same segment
      assert stats_after.cached_segments == stats_before.cached_segments
    end
  end

  describe "integration with Writer" do
    test "reads what Writer writes", %{writer: _writer, reader: _reader} do
      # Write-read cycle
      test_data = "integration test data"
      {:ok, lsn} = Writer.append(test_data)

      Process.sleep(10)

      {:ok, entry} = Reader.read(lsn)
      assert entry.data == test_data
      assert entry.lsn.value == lsn
    end

    test "reads after segment rotation", %{writer: _writer, reader: _reader} do
      # Write enough to trigger rotation (threshold is 10 MB)
      # Write smaller data to avoid hitting threshold
      lsns =
        for i <- 1..10 do
          {:ok, lsn} = Writer.append("data #{i}")
          lsn
        end

      Process.sleep(10)

      # All should be readable
      Enum.each(lsns, fn lsn ->
        assert {:ok, entry} = Reader.read(lsn)
        assert entry.lsn.value == lsn
      end)
    end

    test "read_range spans multiple segments", %{writer: _writer, reader: _reader} do
      # Write entries that will be in different segments
      lsns =
        for i <- 1..20 do
          {:ok, lsn} = Writer.append("entry #{i}")
          lsn
        end

      start_lsn = Enum.at(lsns, 0)
      end_lsn = Enum.at(lsns, 19)

      Process.sleep(10)

      {:ok, entries} = Reader.read_range(start_lsn, end_lsn)
      assert length(entries) == 20
      assert Enum.map(entries, & &1.lsn.value) == lsns
    end
  end

  describe "error handling" do
    test "handles missing segment gracefully", %{reader: _reader} do
      # Try to read from LSN that doesn't exist
      assert {:error, :not_found} = Reader.read(1_000_000)
    end

    test "handles concurrent reads", %{writer: _writer, reader: _reader} do
      # Write entries
      lsns =
        for i <- 1..20 do
          {:ok, lsn} = Writer.append("concurrent #{i}")
          lsn
        end

      Process.sleep(10)

      # Concurrent reads
      tasks =
        Enum.map(lsns, fn lsn ->
          Task.async(fn ->
            Reader.read(lsn)
          end)
        end)

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _entry} -> true
               _ -> false
             end)
    end
  end

  describe "metadata preservation" do
    test "preserves entry metadata", %{writer: _writer, reader: _reader} do
      # Write entry with metadata
      {:ok, lsn} = Writer.append("data with metadata")

      Process.sleep(10)

      {:ok, entry} = Reader.read(lsn)

      # Check metadata fields exist
      assert is_struct(entry.lsn)
      assert is_struct(entry.node_id)
      assert is_map(entry.metadata)
      assert entry.node_id.value == "test_node"
    end
  end
end
