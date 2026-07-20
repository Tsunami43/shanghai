defmodule Replication.EpochPersistenceTest do
  @moduledoc """
  A vote must outlive the voter.

  If a restarted node forgets the vote it cast, it can grant a second vote in
  the same epoch and two candidates can each reach a majority - which is the
  one way the quorum guarantee can still produce two leaders. These tests
  restart the store against the same directory and assert the decision holds.
  """

  use ExUnit.Case, async: false

  alias CoreDomain.Types.NodeId
  alias Replication.Epoch

  @dir Path.join(System.tmp_dir!(), "shanghai_epoch_#{:rand.uniform(999_999)}")

  setup do
    File.rm_rf(@dir)
    File.mkdir_p!(@dir)
    on_exit(fn -> File.rm_rf(@dir) end)

    # `start_epoch: false` in the test env keeps the application from owning
    # this singleton, so these tests can restart it freely (see config/test.exs).
    on_exit(fn -> if pid = Process.whereis(Epoch), do: stop_quietly(pid) end)

    :ok
  end

  defp start_store(dir \\ @dir) do
    if pid = Process.whereis(Epoch), do: stop_quietly(pid)
    {:ok, pid} = Epoch.start_link(data_dir: dir)
    pid
  end

  defp stop_quietly(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp restart_store(dir \\ @dir) do
    start_store(dir)
  end

  describe "votes survive a restart" do
    test "a granted vote is still remembered" do
      start_store()
      group = "g1"

      assert :granted = Epoch.grant_vote(group, 3, NodeId.new("a"))

      restart_store()

      assert Epoch.current(group) == 3
      assert Epoch.voted_for(group) == NodeId.new("a")
    end

    test "a restarted node refuses to vote twice in the same epoch" do
      start_store()
      group = "g1"

      assert :granted = Epoch.grant_vote(group, 3, NodeId.new("a"))

      # The node crashes and comes back while the election is still running.
      restart_store()

      assert {:denied, :already_voted} = Epoch.grant_vote(group, 3, NodeId.new("b")),
             "a forgotten vote would let two candidates win the same epoch"
    end

    test "an observed epoch is still remembered" do
      start_store()
      group = "g1"

      Epoch.observe(group, 9)
      restart_store()

      assert Epoch.current(group) == 9
      assert {:denied, :already_voted} = Epoch.grant_vote(group, 9, NodeId.new("a"))
    end

    test "several groups are recovered independently" do
      start_store()

      Epoch.grant_vote("alpha", 1, NodeId.new("a"))
      Epoch.grant_vote("beta", 4, NodeId.new("b"))

      restart_store()

      assert Epoch.current("alpha") == 1
      assert Epoch.current("beta") == 4
      assert Epoch.voted_for("beta") == NodeId.new("b")
    end

    test "a group id that is not a safe filename round-trips" do
      start_store()
      group = "tenant/42:shard-1 with spaces"

      assert :granted = Epoch.grant_vote(group, 2, NodeId.new("a"))
      restart_store()

      assert Epoch.current(group) == 2
    end

    test "forget/1 removes the persisted record too" do
      start_store()
      group = "g1"

      Epoch.grant_vote(group, 5, NodeId.new("a"))
      Epoch.forget(group)

      restart_store()

      assert Epoch.current(group) == 0
    end
  end

  describe "degraded modes" do
    test "runs in memory when no directory is configured" do
      start_store(nil)

      assert :granted = Epoch.grant_vote("g1", 1, NodeId.new("a"))
      assert Epoch.current("g1") == 1
    end

    test "a corrupt record is ignored rather than crashing the store" do
      start_store()
      group = "g1"
      Epoch.grant_vote(group, 5, NodeId.new("a"))

      stop_quietly(Process.whereis(Epoch))

      # Truncate the stored record to something undecodable.
      [path] = Path.wildcard(Path.join(@dir, "*.epoch"))
      File.write!(path, "not a term")

      start_store()

      # The group falls back to zero rather than taking the store down; a
      # guessed epoch would be worse than none.
      assert Epoch.current(group) == 0
    end
  end
end
