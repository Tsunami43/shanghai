defmodule ShanghaictlTest do
  use ExUnit.Case, async: true

  alias Shanghaictl.Commands.{Health, Metrics, Status}

  doctest Shanghaictl

  describe "parse/1" do
    test "no args and 'help' map to :help" do
      assert Shanghaictl.parse([]) == :help
      assert Shanghaictl.parse(["help"]) == :help
    end

    test "'version' maps to :version" do
      assert Shanghaictl.parse(["version"]) == :version
    end

    test "read commands carry their options" do
      assert Shanghaictl.parse(["status", "--format", "json"]) == {:status, ["--format", "json"]}
      assert Shanghaictl.parse(["replicas"]) == {:replicas, []}
      assert Shanghaictl.parse(["metrics"]) == {:metrics, []}
      assert Shanghaictl.parse(["health"]) == {:health, []}
    end

    test "node join/leave/get are distinguished" do
      assert Shanghaictl.parse(["node", "join", "n1", "--host", "h"]) ==
               {:node_join, ["n1", "--host", "h"]}

      assert Shanghaictl.parse(["node", "leave", "n1"]) == {:node_leave, ["n1"]}
      assert Shanghaictl.parse(["node", "get", "n1"]) == {:node_get, ["n1"]}
    end

    test "shutdown carries its options" do
      assert Shanghaictl.parse(["shutdown", "--graceful"]) == {:shutdown, ["--graceful"]}
    end

    test "kv get carries the key and options" do
      assert Shanghaictl.parse(["kv", "get", "user:1"]) == {:kv_get, ["user:1"]}

      assert Shanghaictl.parse(["kv", "get", "k", "--admin-url", "http://h:9090"]) ==
               {:kv_get, ["k", "--admin-url", "http://h:9090"]}
    end

    test "kv count carries an optional prefix and options" do
      assert Shanghaictl.parse(["kv", "count"]) == {:kv_count, []}
      assert Shanghaictl.parse(["kv", "count", "user:"]) == {:kv_count, ["user:"]}
    end

    test "kv without a subcommand is :unknown" do
      assert Shanghaictl.parse(["kv"]) == {:unknown, ["kv"]}
    end

    test "unrecognized input is :unknown with the original args" do
      assert Shanghaictl.parse(["bogus", "x"]) == {:unknown, ["bogus", "x"]}
      assert Shanghaictl.parse(["node"]) == {:unknown, ["node"]}
    end
  end

  describe "Metrics.store_lines/1" do
    test "renders store and cache figures" do
      store = %{
        "store" => %{"durable" => false, "recovered" => 0, "size" => 3},
        "cache" => %{
          "size" => 2,
          "max_size" => 10_000,
          "hits" => 8,
          "misses" => 2,
          "hit_ratio" => 0.8
        }
      }

      lines = Metrics.store_lines(store)
      joined = Enum.join(lines, "\n")

      assert joined =~ "Keys: 3"
      assert joined =~ "Hits: 8"
      assert joined =~ "Hit Ratio: 0.8"
    end

    test "falls back to a no-data line" do
      assert Metrics.store_lines(nil) == ["Store Metrics: No data"]
      assert Metrics.store_lines(%{}) == ["Store Metrics: No data"]
    end
  end

  describe "Metrics.storage_lines/1" do
    test "renders WAL size figures" do
      storage = %{
        "wal_running" => true,
        "segments" => 2,
        "current_lsn" => 100,
        "entries" => 100,
        "bytes" => 4096
      }

      joined = storage |> Metrics.storage_lines() |> Enum.join("\n")

      assert joined =~ "Segments: 2"
      assert joined =~ "Entries: 100"
      assert joined =~ "Size: 4096 bytes"
    end

    test "falls back to a no-data line" do
      assert Metrics.storage_lines(nil) == ["Storage (WAL): No data"]
      assert Metrics.storage_lines(%{}) == ["Storage (WAL): No data"]
    end
  end

  describe "Status.local_node_line/1" do
    test "renders the local node id when present" do
      assert Status.local_node_line("node-1") == "Local Node:    node-1"
    end

    test "is nil when absent" do
      assert Status.local_node_line(nil) == nil
    end
  end

  describe "Health.to_json/1" do
    test "round-trips the readiness body as JSON" do
      body = %{"status" => "ready", "checks" => %{"query_store" => true}}

      decoded = body |> Health.to_json() |> Jason.decode!()

      assert decoded["status"] == "ready"
      assert decoded["checks"]["query_store"] == true
    end
  end

  describe "Status.to_json/1" do
    test "encodes the cluster info as JSON" do
      info = %{
        cluster_state: :healthy,
        local_node_id: "node-1",
        nodes: [%{id: "node-1", status: :up, heartbeat_age: 50}]
      }

      decoded = info |> Status.to_json() |> Jason.decode!()

      assert decoded["cluster_state"] == "healthy"
      assert decoded["local_node_id"] == "node-1"
      assert [node] = decoded["nodes"]
      assert node["id"] == "node-1"
      assert node["status"] == "up"
      assert node["heartbeat_age_ms"] == 50
    end
  end
end
