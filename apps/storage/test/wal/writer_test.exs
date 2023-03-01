defmodule Storage.WAL.WriterTest do
  use ExUnit.Case, async: false

  alias Storage.WAL.{Writer, SegmentManager}
  alias Storage.Index.SegmentIndex

  @test_dir Path.join(System.tmp_dir!(), "shanghai_writer_test_#{:rand.uniform(999_999)}")
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

    # Start Writer
    {:ok, writer_pid} =
      Writer.start_link(
        data_dir: @test_dir,
        node_id: "test_node",
        segment_size_threshold: 1024,  # Small threshold for testing rotation
        segment_time_threshold: 3600
      )

    on_exit(fn ->
      if Process.alive?(writer_pid), do: GenServer.stop(writer_pid)
      if Process.alive?(index_pid), do: GenServer.stop(index_pid)

      # Stop all segments
      SegmentManager.list_segments()
      |> Enum.each(fn {id, _pid} ->
        SegmentManager.stop_segment(id)
      end)

      File.rm_rf(@test_dir)
    end)

    {:ok, writer: writer_pid, index: index_pid}
  end

  describe "append/1" do
    test "appends single entry", %{writer: _writer} do
      assert {:ok, lsn} = Writer.append("test data")
      assert lsn == 0
    end

    test "appends multiple entries with incrementing LSNs", %{writer: _writer} do
      {:ok, lsn1} = Writer.append("entry 1")
      {:ok, lsn2} = Writer.append("entry 2")
      {:ok, lsn3} = Writer.append("entry 3")

      assert lsn1 == 0
      assert lsn2 == 1
      assert lsn3 == 2
    end

    test "updates SegmentIndex after append", %{writer: _writer} do
      {:ok, lsn} = Writer.append("indexed data")

      # Give index time to update
      Process.sleep(10)

      assert {:ok, {_segment_id, _offset}} = SegmentIndex.lookup(SegmentIndex, lsn)
    end

    test "persists metadata periodically", %{writer: _writer} do
      # Append more than persist interval (100)
      for i <- 1..105 do
        Writer.append("entry #{i}")
      end

      # Check metadata file exists
      metadata_path = Path.join(@test_dir, "wal_metadata.dat")
      assert File.exists?(metadata_path)
    end

    test "handles various data types", %{writer: _writer} do
      assert {:ok, _} = Writer.append("string")
      assert {:ok, _} = Writer.append(12345)
      assert {:ok, _} = Writer.append(%{key: "value"})
      assert {:ok, _} = Writer.append([1, 2, 3])
      assert {:ok, _} = Writer.append({:tuple, "data"})
    end
  end

  describe "info/0" do
    test "returns current writer state", %{writer: _writer} do
      Writer.append("test")
      Writer.append("test2")

      assert {:ok, info} = Writer.info()
      assert info.current_lsn == 2
      assert info.current_segment_id == 1
      assert info.append_count == 2
      assert is_integer(info.segment_start_time)
    end
  end

  describe "segment rotation" do
    test "rotates segment when size threshold exceeded", %{writer: _writer} do
      # Append enough data to exceed 1024 byte threshold
      large_data = String.duplicate("x", 200)

      for _i <- 1..10 do
        Writer.append(large_data)
      end

      # Give time for rotation
      Process.sleep(100)

      {:ok, info} = Writer.info()

      # Should have rotated to segment 2 or higher
      assert info.current_segment_id >= 2
    end

    test "seals old segment after rotation", %{writer: _writer} do
      # Trigger rotation
      large_data = String.duplicate("x", 200)

      for _i <- 1..10 do
        Writer.append(large_data)
      end

      Process.sleep(100)

      # Try to find sealed segment (segment 1)
      case SegmentManager.get_segment(1) do
        {:ok, seg_pid} ->
          {:ok, seg_info} = Storage.WAL.Segment.info(seg_pid)
          # Segment should be sealed
          assert seg_info.sealed == true

        {:error, :not_found} ->
          # Segment was stopped, which is also fine
          assert true
      end
    end

    test "continues LSN sequence across rotation", %{writer: _writer} do
      {:ok, lsn1} = Writer.append("before rotation")

      # Trigger rotation
      large_data = String.duplicate("x", 200)

      for _i <- 1..10 do
        Writer.append(large_data)
      end

      {:ok, lsn_after} = Writer.append("after rotation")

      # LSN should continue sequentially
      assert lsn_after > lsn1
    end
  end

  describe "persistence and recovery" do
    test "recovers state from metadata on restart", %{writer: writer_pid, index: index_pid} do
      # Write some entries
      for i <- 1..10 do
        Writer.append("entry #{i}")
      end

      {:ok, info_before} = Writer.info()

      # Stop writer
      GenServer.stop(writer_pid)

      # Wait for graceful shutdown
      Process.sleep(100)

      # Restart writer with same data_dir
      {:ok, new_writer_pid} =
        Writer.start_link(
          data_dir: @test_dir,
          node_id: "test_node",
          segment_size_threshold: 1024,
          segment_time_threshold: 3600
        )

      {:ok, info_after} = Writer.info()

      # Should resume from where it left off
      assert info_after.current_lsn == info_before.current_lsn
      assert info_after.current_segment_id == info_before.current_segment_id

      # Cleanup
      if Process.alive?(new_writer_pid), do: GenServer.stop(new_writer_pid)
    end

    test "appends after recovery", %{writer: writer_pid, index: _index} do
      # Write entries
      Writer.append("entry 1")
      Writer.append("entry 2")

      {:ok, info_before} = Writer.info()

      # Restart
      GenServer.stop(writer_pid)
      Process.sleep(100)

      {:ok, new_writer_pid} =
        Writer.start_link(
          data_dir: @test_dir,
          node_id: "test_node",
          segment_size_threshold: 1024,
          segment_time_threshold: 3600
        )

      # Append new entry
      {:ok, new_lsn} = Writer.append("entry 3")

      # Should continue from previous LSN
      assert new_lsn == info_before.current_lsn

      # Cleanup
      if Process.alive?(new_writer_pid), do: GenServer.stop(new_writer_pid)
    end
  end

  describe "error handling" do
    test "handles concurrent appends", %{writer: _writer} do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            Writer.append("concurrent #{i}")
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _lsn} -> true
               _ -> false
             end)

      # All LSNs should be unique
      lsns = Enum.map(results, fn {:ok, lsn} -> lsn end)
      assert length(Enum.uniq(lsns)) == 50
    end
  end

  describe "integration" do
    test "written entries can be looked up in index", %{writer: _writer} do
      lsns =
        for i <- 1..10 do
          {:ok, lsn} = Writer.append("entry #{i}")
          lsn
        end

      # Give index time to flush
      Process.sleep(100)

      # All LSNs should be in index
      Enum.each(lsns, fn lsn ->
        assert {:ok, {_segment_id, _offset}} = SegmentIndex.lookup(SegmentIndex, lsn)
      end)
    end
  end
end
