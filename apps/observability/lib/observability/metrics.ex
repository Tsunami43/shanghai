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
  @spec wal_write_completed(number(), non_neg_integer(), term()) :: :ok
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
  @spec wal_sync_completed(number(), term()) :: :ok
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
  @spec replication_lag_measured(number(), number(), term(), term(), term()) :: :ok
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
  @spec replication_catchup_completed(number(), non_neg_integer(), term(), term()) :: :ok
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
  @spec heartbeat_completed(number(), term(), term()) :: :ok
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
  @spec cluster_membership_changed(non_neg_integer(), atom(), term()) :: :ok
  def cluster_membership_changed(node_count, event_type, node_id) do
    :telemetry.execute(
      [:shanghai, :cluster, :membership_change],
      %{node_count: node_count},
      %{event_type: event_type, node_id: node_id}
    )
  end

  @doc """
  Reports that the deterministic cluster leader changed.

  Emits: `[:shanghai, :cluster, :leader_elected]`

  Measurements:
  - `:up_count` - Number of `:up` nodes at election time

  Metadata:
  - `:leader` - The elected leader's node id, or `nil` when no node is up
  - `:previous` - The previous leader's node id, or `nil`
  """
  @spec leader_elected(non_neg_integer(), term(), term()) :: :ok
  def leader_elected(up_count, leader, previous) do
    :telemetry.execute(
      [:shanghai, :cluster, :leader_elected],
      %{up_count: up_count},
      %{leader: leader, previous: previous}
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
  @spec compaction_completed(number(), non_neg_integer(), non_neg_integer(), list()) :: :ok
  def compaction_completed(duration_ms, bytes_before, bytes_after, segment_ids) do
    :telemetry.execute(
      [:shanghai, :storage, :compaction, :complete],
      %{duration_ms: duration_ms, bytes_before: bytes_before, bytes_after: bytes_after},
      %{segment_ids: segment_ids}
    )
  end

  @doc """
  Reports completion of a user-facing query operation.

  Emits: `[:shanghai, :query, :operation]`

  Measurements:
  - `:duration_ms` - Operation duration in milliseconds

  Metadata:
  - `:operation` - The operation performed (`:read`, `:write`, `:delete`, `:transact`)
  - `:result` - Outcome tag (`:ok` or `:error`)
  """
  @spec query_operation_completed(atom(), number(), atom()) :: :ok
  def query_operation_completed(operation, duration_ms, result) do
    :telemetry.execute(
      [:shanghai, :query, :operation],
      %{duration_ms: duration_ms},
      %{operation: operation, result: result}
    )
  end

  @doc """
  Returns a list of all defined telemetry event names.
  """
  @spec event_names() :: [[atom()]]
  def event_names do
    [
      [:shanghai, :storage, :wal, :write],
      [:shanghai, :storage, :wal, :sync],
      [:shanghai, :replication, :lag],
      [:shanghai, :replication, :catchup],
      [:shanghai, :cluster, :heartbeat],
      [:shanghai, :cluster, :membership_change],
      [:shanghai, :cluster, :leader_elected],
      [:shanghai, :storage, :compaction, :complete],
      [:shanghai, :query, :operation]
    ]
  end

  @doc """
  Returns `true` when `event` is one of the telemetry events Shanghai emits.

  ## Examples

      iex> Observability.Metrics.event_defined?([:shanghai, :query, :operation])
      true

      iex> Observability.Metrics.event_defined?([:shanghai, :unknown])
      false
  """
  @spec event_defined?([atom()]) :: boolean()
  def event_defined?(event) when is_list(event), do: event in event_names()

  @doc "Returns `true` when the domain has at least one defined telemetry event."
  @spec domain?(atom()) :: boolean()
  def domain?(domain) when is_atom(domain), do: events_for_domain(domain) != []

  @doc "Returns the number of distinct telemetry events Shanghai emits."
  @spec event_count() :: non_neg_integer()
  def event_count, do: length(event_names())

  @doc """
  Returns the telemetry event names belonging to `domain` (the second path
  segment, e.g. `:storage`, `:replication`, `:cluster`, `:query`).

  ## Examples

      iex> Observability.Metrics.events_for_domain(:query)
      [[:shanghai, :query, :operation]]
  """
  @spec events_for_domain(atom()) :: [[atom()]]
  def events_for_domain(domain) when is_atom(domain) do
    Enum.filter(event_names(), fn
      [:shanghai, ^domain | _rest] -> true
      _ -> false
    end)
  end

  @doc """
  Returns the distinct telemetry domains (the second path segment of each event
  name), sorted.

  ## Examples

      iex> :query in Observability.Metrics.domains()
      true
  """
  @spec domains() :: [atom()]
  def domains do
    event_names()
    |> Enum.map(fn [:shanghai, domain | _rest] -> domain end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Returns a map of `domain => event_count` — how many telemetry events each
  domain emits.

  ## Examples

      iex> Observability.Metrics.domain_event_counts()[:query]
      1
  """
  @spec domain_event_counts() :: %{optional(atom()) => non_neg_integer()}
  def domain_event_counts do
    Enum.frequencies_by(event_names(), fn [:shanghai, domain | _rest] -> domain end)
  end

  @doc """
  Returns the domain (second path segment) of a telemetry event, or `nil` when
  the event is not one Shanghai emits.

  ## Examples

      iex> Observability.Metrics.event_domain([:shanghai, :query, :operation])
      :query
  """
  @spec event_domain([atom()]) :: atom() | nil
  def event_domain([:shanghai, domain | _rest] = event) do
    if event_defined?(event), do: domain, else: nil
  end

  def event_domain(_event), do: nil
end
