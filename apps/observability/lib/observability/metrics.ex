defmodule Observability.Metrics do
  @moduledoc """
  Defines telemetry metrics for Shanghai distributed database.

  ## Metric Categories

  ### Storage Metrics
  - WAL write latency
  - WAL sync latency
  - Compaction duration

  ### Replication Metrics
  - Replication lag per replica
  - Replication stream throughput
  - Follower catch-up time

  ### Cluster Metrics
  - Heartbeat round-trip time (RTT)
  - Node up/down events
  - Cluster membership changes

  ## Usage

  This module provides convenience functions for emitting telemetry events.
  Consumers can attach handlers using `:telemetry.attach/4` or `:telemetry.attach_many/4`.

  Example:

      # Emit a WAL write metric
      Observability.Metrics.wal_write_completed(duration_ms, bytes_written)

      # Attach a handler
      :telemetry.attach(
        "my-handler",
        [:shanghai, :storage, :wal, :write],
        &MyModule.handle_event/4,
        nil
      )
  """

  @doc """
  Reports WAL write completion.

  Emits: `[:shanghai, :storage, :wal, :write]`

  Measurements:
  - `:duration` - Write duration in milliseconds
  - `:bytes` - Number of bytes written

  Metadata:
  - `:segment_id` - WAL segment identifier
  """
  def wal_write_completed(duration_ms, bytes, segment_id) do
    :telemetry.execute(
      [:shanghai, :storage, :wal, :write],
      %{duration: duration_ms, bytes: bytes},
      %{segment_id: segment_id}
    )
  end

  @doc """
  Reports WAL fsync completion.

  Emits: `[:shanghai, :storage, :wal, :sync]`

  Measurements:
  - `:duration` - Sync duration in milliseconds

  Metadata:
  - `:segment_id` - WAL segment identifier
  """
  def wal_sync_completed(duration_ms, segment_id) do
    :telemetry.execute(
      [:shanghai, :storage, :wal, :sync],
      %{duration: duration_ms},
      %{segment_id: segment_id}
    )
  end

  @doc """
  Reports replication lag for a follower.

  Emits: `[:shanghai, :replication, :lag]`

  Measurements:
  - `:offset_lag` - Difference in offsets between leader and follower
  - `:time_lag_ms` - Time lag in milliseconds

  Metadata:
  - `:group_id` - Replication group identifier
  - `:follower_id` - Follower node identifier
  - `:leader_id` - Leader node identifier
  """
  def replication_lag_measured(offset_lag, time_lag_ms, group_id, follower_id, leader_id) do
    :telemetry.execute(
      [:shanghai, :replication, :lag],
      %{offset_lag: offset_lag, time_lag_ms: time_lag_ms},
      %{group_id: group_id, follower_id: follower_id, leader_id: leader_id}
    )
  end

  @doc """
  Reports follower catch-up event.

  Emits: `[:shanghai, :replication, :catchup]`

  Measurements:
  - `:duration_ms` - Time taken to catch up
  - `:records_replicated` - Number of records replicated during catch-up

  Metadata:
  - `:group_id` - Replication group identifier
  - `:follower_id` - Follower node identifier
  """
  def replication_catchup_completed(duration_ms, records, group_id, follower_id) do
    :telemetry.execute(
      [:shanghai, :replication, :catchup],
      %{duration_ms: duration_ms, records_replicated: records},
      %{group_id: group_id, follower_id: follower_id}
    )
  end

  @doc """
  Reports heartbeat round-trip time.

  Emits: `[:shanghai, :cluster, :heartbeat]`

  Measurements:
  - `:rtt_ms` - Round-trip time in milliseconds

  Metadata:
  - `:source_node` - Node that sent the heartbeat
  - `:target_node` - Node that received the heartbeat
  """
  def heartbeat_completed(rtt_ms, source_node, target_node) do
    :telemetry.execute(
      [:shanghai, :cluster, :heartbeat],
      %{rtt_ms: rtt_ms},
      %{source_node: source_node, target_node: target_node}
    )
  end

  @doc """
  Reports cluster membership change.

  Emits: `[:shanghai, :cluster, :membership_change]`

  Measurements:
  - `:node_count` - Current number of nodes in cluster

  Metadata:
  - `:event_type` - Type of change (`:node_joined`, `:node_left`, `:node_down`)
  - `:node_id` - Node affected by the change
  """
  def cluster_membership_changed(node_count, event_type, node_id) do
    :telemetry.execute(
      [:shanghai, :cluster, :membership_change],
      %{node_count: node_count},
      %{event_type: event_type, node_id: node_id}
    )
  end

  @doc """
  Reports compaction completion.

  Emits: `[:shanghai, :storage, :compaction, :complete]`

  Measurements:
  - `:duration_ms` - Compaction duration in milliseconds
  - `:bytes_before` - Size before compaction
  - `:bytes_after` - Size after compaction

  Metadata:
  - `:segment_ids` - List of segments compacted
  """
  def compaction_completed(duration_ms, bytes_before, bytes_after, segment_ids) do
    :telemetry.execute(
      [:shanghai, :storage, :compaction, :complete],
      %{duration_ms: duration_ms, bytes_before: bytes_before, bytes_after: bytes_after},
      %{segment_ids: segment_ids}
    )
  end

  @doc """
  Returns a list of all defined telemetry event names.
  """
  def event_names do
    [
      [:shanghai, :storage, :wal, :write],
      [:shanghai, :storage, :wal, :sync],
      [:shanghai, :replication, :lag],
      [:shanghai, :replication, :catchup],
      [:shanghai, :cluster, :heartbeat],
      [:shanghai, :cluster, :membership_change],
      [:shanghai, :storage, :compaction, :complete]
    ]
  end
end
