defmodule Shanghaictl.Commands.StorageTest do
  use ExUnit.Case, async: true

  alias Shanghaictl.Commands.Storage

  describe "storage_lines/1" do
    test "renders a storage overview with human-readable figures" do
      storage = %{
        "durable" => true,
        "active_segments" => 2,
        "entries" => 10,
        "bytes" => 4096,
        "snapshots" => 1,
        "latest_snapshot_lsn" => 900,
        "compaction_running" => false
      }

      joined = storage |> Storage.storage_lines() |> Enum.join("\n")

      assert joined =~ "Durable: yes"
      assert joined =~ "Segments: 2"
      assert joined =~ "Entries: 10"
      assert joined =~ "Size: 4.0 KB"
      assert joined =~ "Snapshots: 1"
      assert joined =~ "Latest Snapshot LSN: 900"
      assert joined =~ "Compaction Running: no"
    end

    test "renders 'none' when there is no snapshot LSN" do
      storage = %{"latest_snapshot_lsn" => nil}
      joined = storage |> Storage.storage_lines() |> Enum.join("\n")
      assert joined =~ "Latest Snapshot LSN: none"
    end
  end
end
