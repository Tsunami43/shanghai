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

  describe "health_ratio/1" do
    test "is the fraction of passing checks" do
      assert Admin.Health.health_ratio(%{}) == 1.0
      assert Admin.Health.health_ratio(%{a: true, b: true}) == 1.0
      assert Admin.Health.health_ratio(%{a: true, b: false}) == 0.5
      assert Admin.Health.health_ratio(%{a: false, b: false}) == 0.0
    end
  end

  describe "health/0" do
    test "reports every subsystem and an overall status" do
      report = Admin.health()

      assert Enum.sort(Map.keys(report.checks)) == [:cluster, :query, :replication, :storage]
      assert report.status in [:healthy, :degraded]
    end

    test "reflects the live liveness of every subsystem process" do
      # Derive the expected status from the actual process liveness so this stays
      # correct even when sibling umbrella suites transiently stop a monitored
      # process during a parallel run.
      report = Admin.health()
      assert report.status == expected_status()
    end
  end

  describe "healthy?/0 and unhealthy_subsystems/0" do
    test "reflect the current subsystem liveness" do
      assert Admin.healthy?() == (expected_status() == :healthy)
      assert Admin.Health.unhealthy_subsystems() == expected_unhealthy()
      assert Admin.unhealthy_subsystems() == expected_unhealthy()
    end
  end

  describe "degraded?/0" do
    test "is the inverse of healthy?/0" do
      assert Admin.degraded?() == not Admin.healthy?()
      assert Admin.Health.degraded?() == not Admin.Health.healthy?()
    end
  end

  describe "healthy_subsystems/0" do
    test "lists the passing subsystems and complements the unhealthy set" do
      healthy = Admin.Health.healthy_subsystems()
      assert healthy == expected_healthy()
      assert Admin.healthy_subsystems() == healthy
      assert healthy -- Admin.Health.unhealthy_subsystems() == healthy
    end
  end

  describe "summary/0" do
    test "aggregates subsystem health into a compact map" do
      summary = Admin.Health.summary()

      assert summary.status in [:healthy, :degraded]
      assert summary.total == 4
      assert summary.healthy == summary.total - length(summary.unhealthy)
      assert summary.ratio >= 0.0 and summary.ratio <= 1.0
      assert is_list(summary.unhealthy)
    end

    test "is exposed on the Admin facade" do
      assert Admin.summary() == Admin.Health.summary()
    end

    test "health_ratio/0 mirrors the summary ratio" do
      assert Admin.health_ratio() == Admin.summary().ratio
      assert Admin.health_ratio() >= 0.0 and Admin.health_ratio() <= 1.0
    end
  end

  # The subsystem => monitored process map mirrors Admin.Health.check/0.
  @subsystems %{
    storage: Storage.WAL.SegmentManager,
    cluster: Cluster.Membership,
    replication: Replication.Monitor,
    query: Query.Store
  }

  defp live_checks do
    Map.new(@subsystems, fn {name, proc} -> {name, is_pid(Process.whereis(proc))} end)
  end

  defp expected_status do
    if Enum.all?(Map.values(live_checks())), do: :healthy, else: :degraded
  end

  defp expected_unhealthy do
    live_checks()
    |> Enum.filter(fn {_name, up?} -> not up? end)
    |> Enum.map(fn {name, _up?} -> name end)
    |> Enum.sort()
  end

  defp expected_healthy do
    live_checks()
    |> Enum.filter(fn {_name, up?} -> up? end)
    |> Enum.map(fn {name, _up?} -> name end)
    |> Enum.sort()
  end
end
