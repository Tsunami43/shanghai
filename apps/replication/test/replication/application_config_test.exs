defmodule Replication.ApplicationConfigTest do
  @moduledoc "The replication app resolves Monitor options from config."

  use ExUnit.Case, async: false

  alias Replication.Application, as: ReplicationApp

  test "monitor_opts is empty when unconfigured (Monitor uses its own defaults)" do
    assert ReplicationApp.monitor_opts() == []
  end

  test "monitor_opts reads config :replication, Replication.Monitor" do
    Application.put_env(:replication, Replication.Monitor,
      lag_threshold: 42,
      stale_threshold_ms: 111,
      check_interval_ms: 999
    )

    on_exit(fn -> Application.delete_env(:replication, Replication.Monitor) end)

    opts = ReplicationApp.monitor_opts()
    assert opts[:lag_threshold] == 42
    assert opts[:stale_threshold_ms] == 111
    assert opts[:check_interval_ms] == 999
  end
end
