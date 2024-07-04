defmodule Shanghaictl.Commands.TopologyTest do
  use ExUnit.Case, async: true

  alias Shanghaictl.Commands.Topology

  describe "topology_lines/1" do
    test "renders the topology summary and node list" do
      topology = %{
        "local_node_id" => "local",
        "node_count" => 2,
        "status_summary" => %{"up" => 1, "suspect" => 0, "down" => 1},
        "nodes" => [
          %{"id" => "n1", "address" => "hostA:4001", "status" => "up"},
          %{"id" => "n2", "address" => "hostB:4002", "status" => "down"}
        ]
      }

      joined = topology |> Topology.topology_lines() |> Enum.join("\n")

      assert joined =~ "Local Node: local"
      assert joined =~ "Nodes: 2 (up 1, suspect 0, down 1)"
      assert joined =~ "- n1 @ hostA:4001 [up]"
      assert joined =~ "- n2 @ hostB:4002 [down]"
    end

    test "handles an empty node list" do
      lines = Topology.topology_lines(%{"node_count" => 0, "nodes" => []})
      assert Enum.any?(lines, &(&1 =~ "Nodes: 0"))
    end
  end
end
