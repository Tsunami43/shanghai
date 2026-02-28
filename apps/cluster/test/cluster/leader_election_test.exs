defmodule Cluster.LeaderElectionTest do
  use ExUnit.Case, async: false

  alias Cluster.Entities.Node
  alias Cluster.{LeaderElection, Membership}
  alias CoreDomain.Types.NodeId

  setup do
    start_supervised!({Membership, [node_id: "test_local"]})
    start_supervised!({LeaderElection, []})
    :ok
  end

  defp join(id_value) do
    :ok = Membership.join_node(Node.new(NodeId.new(id_value), "localhost", 4000))
  end

  describe "elect/0 and leader/0" do
    test "no leader when no node is up" do
      assert LeaderElection.leader() == nil
      refute LeaderElection.leader?()
    end

    test "elects the lexicographically smallest up node" do
      join("n3")
      join("n1")
      join("n2")

      assert LeaderElection.elect() == NodeId.new("n1")
      assert LeaderElection.leader() == NodeId.new("n1")
      assert LeaderElection.leader?(NodeId.new("n1"))
      refute LeaderElection.leader?(NodeId.new("n2"))
    end
  end

  describe "re-election on membership change" do
    test "promotes the next smallest node when the leader leaves" do
      join("n1")
      join("n2")
      assert LeaderElection.leader() == NodeId.new("n1")

      :ok = Membership.leave_node(NodeId.new("n1"))

      # leave_node broadcasts before replying, so the re-election is already
      # queued ahead of this synchronous call.
      assert LeaderElection.leader() == NodeId.new("n2")
    end

    test "clears the leader when the last node leaves" do
      join("solo")
      assert LeaderElection.leader() == NodeId.new("solo")

      :ok = Membership.leave_node(NodeId.new("solo"))
      assert LeaderElection.leader() == nil
    end
  end

  describe "telemetry" do
    test "emits [:shanghai, :cluster, :leader_elected] on a leader change" do
      test_pid = self()

      :telemetry.attach(
        "le-test",
        [:shanghai, :cluster, :leader_elected],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:leader_elected, measurements, metadata})
        end,
        nil
      )

      join("n2")

      assert_receive {:leader_elected, %{up_count: 1}, %{leader: leader, previous: nil}}
      assert leader == NodeId.new("n2")

      join("n1")
      assert_receive {:leader_elected, %{up_count: 2}, %{leader: new_leader, previous: previous}}
      assert new_leader == NodeId.new("n1")
      assert previous == NodeId.new("n2")
    after
      :telemetry.detach("le-test")
    end
  end
end
