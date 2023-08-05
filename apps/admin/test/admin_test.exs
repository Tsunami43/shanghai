defmodule AdminTest do
  use ExUnit.Case, async: false

  setup_all do
    # The cluster app omits its `mod:` under the test env, and Replication.Monitor
    # is disabled there, so start them explicitly for a healthy report.
    case Cluster.Application.start(:normal, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Replication.Monitor.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "status_of/1" do
    test "healthy when all checks pass" do
      assert Admin.Health.status_of(%{storage: true, cluster: true}) == :healthy
    end

    test "degraded when any check fails" do
      assert Admin.Health.status_of(%{storage: true, cluster: false}) == :degraded
    end
  end

  describe "health/0" do
    test "reports every subsystem and an overall status" do
      report = Admin.health()

      assert Enum.sort(Map.keys(report.checks)) == [:cluster, :query, :replication, :storage]
      assert report.status in [:healthy, :degraded]
    end

    test "is healthy when all subsystem processes are running" do
      assert Admin.health().status == :healthy
    end
  end

  describe "healthy?/0 and unhealthy_subsystems/0" do
    test "reflect a fully healthy system" do
      assert Admin.healthy?()
      assert Admin.Health.unhealthy_subsystems() == []
    end
  end
end
