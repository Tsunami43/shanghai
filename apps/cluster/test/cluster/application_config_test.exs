defmodule Cluster.ApplicationConfigTest do
  @moduledoc "The cluster app resolves heartbeat/gossip options from config."

  use ExUnit.Case, async: false

  alias Cluster.Application, as: ClusterApp

  test "heartbeat_opts uses documented defaults" do
    opts = ClusterApp.heartbeat_opts()

    assert opts[:interval_ms] == 5_000
    assert opts[:timeout_ms] == 15_000
    assert opts[:suspect_timeout_ms] == 10_000
  end

  test "heartbeat_opts honors :cluster config overrides" do
    Application.put_env(:cluster, :heartbeat_interval_ms, 1_234)
    Application.put_env(:cluster, :suspect_timeout_ms, 2_222)
    Application.put_env(:cluster, :down_timeout_ms, 3_333)

    on_exit(fn ->
      Application.delete_env(:cluster, :heartbeat_interval_ms)
      Application.delete_env(:cluster, :suspect_timeout_ms)
      Application.delete_env(:cluster, :down_timeout_ms)
    end)

    opts = ClusterApp.heartbeat_opts()
    assert opts[:interval_ms] == 1_234
    assert opts[:suspect_timeout_ms] == 2_222
    assert opts[:timeout_ms] == 3_333
  end

  test "gossip_opts uses defaults and honors overrides" do
    assert ClusterApp.gossip_opts()[:fanout] == 3

    Application.put_env(:cluster, :gossip_fanout, 7)
    Application.put_env(:cluster, :gossip_interval_ms, 500)
    on_exit(fn ->
      Application.delete_env(:cluster, :gossip_fanout)
      Application.delete_env(:cluster, :gossip_interval_ms)
    end)

    opts = ClusterApp.gossip_opts()
    assert opts[:fanout] == 7
    assert opts[:interval_ms] == 500
  end
end
