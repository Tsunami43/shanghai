defmodule Replication.FaultToleranceTest do
  @moduledoc """
  A group's configured size determines how many failures it can survive, and a
  group that cannot survive one must say so at startup rather than offer a false
  sense of high availability.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CoreDomain.Types.NodeId
  alias Replication.GroupCoordinator

  setup do
    ensure_started(fn -> Registry.start_link(keys: :unique, name: Replication.Registry) end)

    ensure_started(fn ->
      DynamicSupervisor.start_link(strategy: :one_for_one, name: Replication.GroupSupervisor)
    end)

    :ok
  end

  describe "fault_tolerance/1" do
    test "matches div(n - 1, 2), and is 0 for one or two members" do
      assert GroupCoordinator.fault_tolerance(1) == 0
      assert GroupCoordinator.fault_tolerance(2) == 0
      assert GroupCoordinator.fault_tolerance(3) == 1
      assert GroupCoordinator.fault_tolerance(4) == 1
      assert GroupCoordinator.fault_tolerance(5) == 2
      assert GroupCoordinator.fault_tolerance(0) == 0
    end
  end

  describe "startup warning" do
    test "a two-member group warns that it cannot fail over" do
      log = start_coordinator_capture([NodeId.new("a"), NodeId.new("b")])
      assert log =~ "tolerates 0 failures"
      assert log =~ "cannot fail over"
    end

    test "a group with no configured members warns that it is unfenced" do
      log = start_coordinator_capture(nil)
      assert log =~ "unfenced"
    end

    test "an even member count is flagged as suboptimal" do
      members = for id <- ["a", "b", "c", "d"], do: NodeId.new(id)
      log = start_coordinator_capture(members)
      assert log =~ "even member count"
    end

    test "a healthy odd group of three does not warn" do
      members = for id <- ["a", "b", "c"], do: NodeId.new(id)
      log = start_coordinator_capture(members)

      refute log =~ "tolerates 0 failures"
      refute log =~ "unfenced"
      refute log =~ "even member count"
    end
  end

  # Starts a coordinator with a stubbed membership/election so nothing tries to
  # reach real peers, and returns the log captured during startup.
  defp start_coordinator_capture(members) do
    group_id = "ft-#{:rand.uniform(1_000_000)}"

    opts =
      [
        group_id: group_id,
        this_node: NodeId.new("a"),
        up_nodes: fn -> [] end,
        elect: fn _g, _m, _c -> {:error, :no_quorum} end
      ] ++ if(members, do: [members: members], else: [])

    capture_log(fn ->
      {:ok, coord} = GroupCoordinator.start_link(opts)
      on_exit(fn -> if Process.alive?(coord), do: GenServer.stop(coord) end)
      # Let init/1 finish so its warning is emitted before capture ends.
      GroupCoordinator.current_role(group_id)
    end)
  end

  defp ensure_started(fun) do
    case fun.() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
