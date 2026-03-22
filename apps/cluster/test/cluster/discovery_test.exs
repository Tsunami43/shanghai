defmodule Cluster.DiscoveryTest do
  use ExUnit.Case, async: false

  alias Cluster.Discovery

  describe "parse_seeds/1" do
    test "normalizes strings and atoms, trimming and de-duplicating" do
      seeds = ["node-1@host", " node-2@host ", :"node-1@host", ""]
      assert Discovery.parse_seeds(seeds) == [:"node-1@host", :"node-2@host"]
    end

    test "wraps a single value and drops non-string/atom entries" do
      assert Discovery.parse_seeds(:n@h) == [:n@h]
      assert Discovery.parse_seeds([123, nil, "n@h"]) == [:n@h]
      assert Discovery.parse_seeds([]) == []
    end
  end

  describe "pending_connections/3" do
    test "excludes the local node and already-connected peers" do
      seeds = [:a@h, :b@h, :c@h]

      assert Discovery.pending_connections(seeds, :a@h, [:b@h]) == [:c@h]
      assert Discovery.pending_connections(seeds, :nonode@nohost, []) == seeds
      assert Discovery.pending_connections(seeds, :a@h, [:b@h, :c@h]) == []
    end
  end

  describe "process" do
    test "seeds/0 reflects the configured seeds and connect_now/0 is a no-op when not distributed" do
      start_supervised!({Discovery, [seed_nodes: ["node-9@localhost"], interval_ms: 60_000]})

      assert Discovery.seeds() == [:"node-9@localhost"]

      # The test node is not distributed (:nonode@nohost), so connecting does
      # nothing rather than failing.
      assert Discovery.connect_now() == []
    end
  end
end
