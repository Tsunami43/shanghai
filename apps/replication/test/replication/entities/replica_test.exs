defmodule Replication.Entities.ReplicaTest do
  use ExUnit.Case, async: true

  alias CoreDomain.Types.NodeId
  alias Replication.Entities.Replica
  alias Replication.ValueObjects.ReplicationOffset

  describe "new_follower/1" do
    test "creates replica as follower with zero offset" do
      node_id = NodeId.new("node1")
      replica = Replica.new_follower(node_id)

      assert replica.node_id == node_id
      assert replica.role == :follower
      assert replica.offset.value == 0
      assert replica.status == :healthy
    end
  end

  describe "new_leader/1" do
    test "creates replica as leader" do
      node_id = NodeId.new("node1")
      replica = Replica.new_leader(node_id)

      assert replica.role == :leader
      assert replica.status == :healthy
    end
  end

  describe "promote_to_leader/1" do
    test "promotes follower to leader" do
      node_id = NodeId.new("node1")
      replica = Replica.new_follower(node_id)

      promoted = Replica.promote_to_leader(replica)

      assert promoted.role == :leader
    end
  end

  describe "demote_to_follower/1" do
    test "demotes leader to follower" do
      node_id = NodeId.new("node1")
      replica = Replica.new_leader(node_id)

      demoted = Replica.demote_to_follower(replica)

      assert demoted.role == :follower
    end
  end

  describe "update_offset/2" do
    test "updates replication offset" do
      node_id = NodeId.new("node1")
      replica = Replica.new_follower(node_id)
      new_offset = ReplicationOffset.new(42)

      updated = Replica.update_offset(replica, new_offset)

      assert updated.offset.value == 42
    end

    test "updates last_heartbeat_at timestamp" do
      node_id = NodeId.new("node1")
      replica = Replica.new_follower(node_id)
      old_heartbeat = replica.last_heartbeat_at

      Process.sleep(10)
      new_offset = ReplicationOffset.new(1)
      updated = Replica.update_offset(replica, new_offset)

      assert DateTime.compare(updated.last_heartbeat_at, old_heartbeat) == :gt
    end
  end

  describe "status changes" do
    test "marks replica as lagging" do
      node_id = NodeId.new("node1")
      replica = Replica.new_follower(node_id)

      lagging = Replica.mark_lagging(replica)

      assert lagging.status == :lagging
    end

    test "marks replica as healthy" do
      node_id = NodeId.new("node1")
      replica = Replica.new_follower(node_id) |> Replica.mark_lagging()

      healthy = Replica.mark_healthy(replica)

      assert healthy.status == :healthy
    end

    test "marks replica as unavailable" do
      node_id = NodeId.new("node1")
      replica = Replica.new_follower(node_id)

      unavailable = Replica.mark_unavailable(replica)

      assert unavailable.status == :unavailable
    end
  end

  describe "predicates" do
    test "leader?/1 returns true for leader" do
      node_id = NodeId.new("node1")
      replica = Replica.new_leader(node_id)

      assert Replica.leader?(replica)
    end

    test "follower?/1 returns true for follower" do
      node_id = NodeId.new("node1")
      replica = Replica.new_follower(node_id)

      assert Replica.follower?(replica)
    end

    test "healthy?/1 returns true for healthy replica" do
      node_id = NodeId.new("node1")
      replica = Replica.new_follower(node_id)

      assert Replica.healthy?(replica)
    end

    test "healthy?/1 returns false for lagging replica" do
      node_id = NodeId.new("node1")
      replica = Replica.new_follower(node_id) |> Replica.mark_lagging()

      refute Replica.healthy?(replica)
    end
  end
end
