# Shanghai Code Examples and Tutorials

This document provides practical examples and tutorials for common Shanghai use cases.

## Table of Contents

- [Basic WAL Operations](#basic-wal-operations)
- [Event Sourcing Pattern](#event-sourcing-pattern)
- [Distributed Counter](#distributed-counter)
- [Message Queue Implementation](#message-queue-implementation)
- [Cluster Management](#cluster-management)
- [Monitoring Integration](#monitoring-integration)
- [Testing Patterns](#testing-patterns)

## Basic WAL Operations

### Simple Write and Read

```elixir
defmodule Examples.BasicWAL do
  alias Storage.WAL.Writer

  def write_message(message) do
    # Serialize data
    data = :erlang.term_to_binary(message)

    # Write to WAL
    case Writer.append(data) do
      {:ok, lsn} ->
        IO.puts("Written to LSN #{lsn}")
        {:ok, lsn}

      {:error, reason} ->
        IO.puts("Write failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def write_many(messages) do
    # Batch multiple writes
    results = Enum.map(messages, fn msg ->
      data = :erlang.term_to_binary(msg)
      Writer.append(data)
    end)

    # Count successes and failures
    successes = Enum.count(results, fn
      {:ok, _lsn} -> true
      _ -> false
    end)

    IO.puts("Wrote #{successes}/#{length(messages)} messages")
    results
  end
end
```

**Usage:**

```elixir
# Single write
Examples.BasicWAL.write_message(%{user_id: 123, action: :login})

# Bulk writes
messages = [
  %{user_id: 123, action: :login},
  %{user_id: 124, action: :signup},
  %{user_id: 125, action: :logout}
]
Examples.BasicWAL.write_many(messages)
```

### High-Throughput Batch Writes

```elixir
defmodule Examples.HighThroughput do
  alias Storage.WAL.BatchWriter

  def generate_load(num_writes) do
    start_time = System.monotonic_time(:millisecond)

    1..num_writes
    |> Task.async_stream(
      fn i ->
        data = :erlang.term_to_binary(%{index: i, timestamp: System.system_time()})
        BatchWriter.append(data)
      end,
      max_concurrency: 100
    )
    |> Enum.to_list()

    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time

    throughput = trunc(num_writes / (duration / 1000))

    IO.puts("""
    Completed #{num_writes} writes in #{duration}ms
    Throughput: #{throughput} writes/sec
    """)
  end
end
```

**Usage:**

```elixir
# Generate 10,000 writes
Examples.HighThroughput.generate_load(10_000)
```

## Event Sourcing Pattern

### Event Store Implementation

```elixir
defmodule Examples.EventStore do
  @moduledoc """
  Event sourcing implementation using Shanghai WAL.
  """

  use GenServer
  alias Storage.WAL.Writer

  @type event :: map()
  @type aggregate_id :: String.t()

  ## Client API

  def start_link(opts \\\\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Appends an event to the event store.
  """
  def append_event(aggregate_id, event_type, data) do
    GenServer.call(__MODULE__, {:append_event, aggregate_id, event_type, data})
  end

  @doc """
  Gets all events for an aggregate.
  """
  def get_events(aggregate_id) do
    GenServer.call(__MODULE__, {:get_events, aggregate_id})
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    state = %{
      # In-memory index: aggregate_id -> [lsns]
      index: %{},
      # In-memory cache: lsn -> event
      cache: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:append_event, aggregate_id, event_type, data}, _from, state) do
    event = %{
      aggregate_id: aggregate_id,
      event_type: event_type,
      data: data,
      timestamp: System.system_time(:millisecond)
    }

    event_bytes = :erlang.term_to_binary(event)

    case Writer.append(event_bytes) do
      {:ok, lsn} ->
        # Update index
        updated_index = Map.update(
          state.index,
          aggregate_id,
          [lsn],
          fn lsns -> [lsn | lsns] end
        )

        # Update cache
        updated_cache = Map.put(state.cache, lsn, event)

        new_state = %{
          state |
          index: updated_index,
          cache: updated_cache
        }

        {:reply, {:ok, lsn}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_events, aggregate_id}, _from, state) do
    lsns = Map.get(state.index, aggregate_id, [])

    # Get events from cache (reverse to chronological order)
    events =
      lsns
      |> Enum.reverse()
      |> Enum.map(fn lsn -> Map.get(state.cache, lsn) end)
      |> Enum.filter(&(&1 != nil))

    {:reply, {:ok, events}, state}
  end
end
```

### Using the Event Store

```elixir
defmodule Examples.BankAccount do
  @moduledoc """
  Bank account aggregate using event sourcing.
  """

  alias Examples.EventStore

  defstruct [:account_id, :balance, :version]

  def open_account(account_id, initial_balance) do
    EventStore.append_event(
      account_id,
      :account_opened,
      %{initial_balance: initial_balance}
    )
  end

  def deposit(account_id, amount) do
    EventStore.append_event(
      account_id,
      :deposited,
      %{amount: amount}
    )
  end

  def withdraw(account_id, amount) do
    # Get current state
    {:ok, account} = get_account(account_id)

    if account.balance >= amount do
      EventStore.append_event(
        account_id,
        :withdrawn,
        %{amount: amount}
      )
    else
      {:error, :insufficient_funds}
    end
  end

  def get_account(account_id) do
    {:ok, events} = EventStore.get_events(account_id)
    account = apply_events(%__MODULE__{account_id: account_id, balance: 0, version: 0}, events)
    {:ok, account}
  end

  # Apply events to rebuild state
  defp apply_events(account, events) do
    Enum.reduce(events, account, &apply_event/2)
  end

  defp apply_event(%{event_type: :account_opened, data: data}, account) do
    %{account | balance: data.initial_balance, version: account.version + 1}
  end

  defp apply_event(%{event_type: :deposited, data: data}, account) do
    %{account | balance: account.balance + data.amount, version: account.version + 1}
  end

  defp apply_event(%{event_type: :withdrawn, data: data}, account) do
    %{account | balance: account.balance - data.amount, version: account.version + 1}
  end
end
```

**Usage:**

```elixir
# Start event store
{:ok, _pid} = Examples.EventStore.start_link()

# Open account
{:ok, _lsn} = Examples.BankAccount.open_account("acc-123", 1000)

# Deposit
{:ok, _lsn} = Examples.BankAccount.deposit("acc-123", 500)

# Withdraw
{:ok, _lsn} = Examples.BankAccount.withdraw("acc-123", 200)

# Get current state
{:ok, account} = Examples.BankAccount.get_account("acc-123")
IO.puts("Balance: $#{account.balance}")  # => Balance: $1300
```

## Distributed Counter

### Counter with Replication

```elixir
defmodule Examples.DistributedCounter do
  @moduledoc """
  A distributed counter that replicates across cluster nodes.
  """

  use GenServer
  require Logger

  alias Storage.WAL.Writer
  alias Cluster.Membership

  defstruct [:node_id, :count, :local_count]

  ## Client API

  def start_link(opts \\\\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def increment do
    GenServer.call(__MODULE__, :increment)
  end

  def get_count do
    GenServer.call(__MODULE__, :get_count)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    node_id = Membership.local_node_id()

    # Subscribe to replication events
    :ok = Membership.subscribe()

    state = %__MODULE__{
      node_id: node_id,
      count: 0,
      local_count: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:increment, _from, state) do
    # Increment local counter
    new_local_count = state.local_count + 1

    # Persist to WAL
    event = %{
      type: :increment,
      node_id: state.node_id.value,
      count: new_local_count,
      timestamp: System.system_time(:millisecond)
    }

    event_bytes = :erlang.term_to_binary(event)

    case Writer.append(event_bytes) do
      {:ok, lsn} ->
        Logger.debug("Increment persisted at LSN #{lsn}")

        new_state = %{
          state |
          local_count: new_local_count,
          count: state.count + 1
        }

        {:reply, {:ok, new_state.count}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_count, _from, state) do
    {:reply, state.count, state}
  end

  @impl true
  def handle_info({:replication_event, %{type: :increment} = event}, state) do
    # Received increment from another node
    if event.node_id != state.node_id.value do
      new_state = %{state | count: state.count + 1}

      Logger.debug("Received remote increment from #{event.node_id}")

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end
end
```

**Usage:**

```elixir
# Start counter on multiple nodes
{:ok, _pid} = Examples.DistributedCounter.start_link()

# Increment on node 1
Examples.DistributedCounter.increment()  # => {:ok, 1}

# After replication to node 2
Examples.DistributedCounter.get_count()  # => 1
```

## Message Queue Implementation

### Simple Queue

```elixir
defmodule Examples.MessageQueue do
  @moduledoc """
  Simple message queue implementation using Shanghai.
  """

  use GenServer
  alias Storage.WAL.Writer

  defstruct [:queue_name, :consumers]

  ## Client API

  def start_link(queue_name) do
    GenServer.start_link(__MODULE__, queue_name, name: via_tuple(queue_name))
  end

  def enqueue(queue_name, message) do
    GenServer.call(via_tuple(queue_name), {:enqueue, message})
  end

  def dequeue(queue_name) do
    GenServer.call(via_tuple(queue_name), :dequeue)
  end

  ## Server Callbacks

  @impl true
  def init(queue_name) do
    state = %__MODULE__{
      queue_name: queue_name,
      consumers: :queue.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, message}, _from, state) do
    # Persist to WAL
    envelope = %{
      queue: state.queue_name,
      message: message,
      timestamp: System.system_time(:millisecond)
    }

    envelope_bytes = :erlang.term_to_binary(envelope)

    case Writer.append(envelope_bytes) do
      {:ok, lsn} ->
        # Broadcast to consumers
        broadcast_to_consumers(state.consumers, {lsn, message})

        {:reply, {:ok, lsn}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:dequeue, {from_pid, _tag}, state) do
    # Add consumer to queue
    updated_consumers = :queue.in(from_pid, state.consumers)

    {:reply, :ok, %{state | consumers: updated_consumers}}
  end

  ## Private Functions

  defp via_tuple(queue_name) do
    {:via, Registry, {Examples.QueueRegistry, queue_name}}
  end

  defp broadcast_to_consumers(consumers, message) do
    case :queue.out(consumers) do
      {{:value, consumer_pid}, _remaining} ->
        send(consumer_pid, {:message, message})

      {:empty, _} ->
        :ok
    end
  end
end
```

**Usage:**

```elixir
# Start queue
{:ok, _pid} = Examples.MessageQueue.start_link("my-queue")

# Producer: enqueue messages
{:ok, lsn} = Examples.MessageQueue.enqueue("my-queue", %{task: "process payment"})

# Consumer: dequeue messages
Examples.MessageQueue.dequeue("my-queue")

receive do
  {:message, {lsn, msg}} ->
    IO.puts("Received: #{inspect(msg)}")
end
```

## Cluster Management

### Adding Nodes Dynamically

```elixir
defmodule Examples.ClusterManager do
  alias Cluster.Membership
  alias Cluster.Entities.Node
  alias CoreDomain.Types.NodeId

  def add_node(node_id, host, port, admin_port \\\\ 9090) do
    node = Node.new(
      node_id: NodeId.new(node_id),
      host: host,
      port: port,
      admin_port: admin_port
    )

    case Membership.join_node(node) do
      :ok ->
        IO.puts("Node #{node_id} joined successfully")

        # Start replication to new node
        start_replication_to(node_id)

        :ok

      {:error, reason} ->
        IO.puts("Failed to add node: #{reason}")
        {:error, reason}
    end
  end

  def remove_node(node_id) do
    case Membership.leave_node(NodeId.new(node_id)) do
      :ok ->
        IO.puts("Node #{node_id} removed successfully")
        :ok

      {:error, reason} ->
        IO.puts("Failed to remove node: #{reason}")
        {:error, reason}
    end
  end

  def list_nodes do
    nodes = Membership.all_nodes()

    IO.puts("\nCluster Nodes:")
    IO.puts(String.duplicate("=", 50))

    Enum.each(nodes, fn node ->
      IO.puts("""
      ID:     #{node.id.value}
      Host:   #{node.host}:#{node.port}
      Status: #{node.status}
      """)
    end)
  end

  defp start_replication_to(node_id) do
    {:ok, _pid} = Replication.Leader.start_link(
      follower_node_id: NodeId.new(node_id),
      start_offset: 0
    )
  end
end
```

**Usage:**

```elixir
# Add a new node
Examples.ClusterManager.add_node("node-4", "10.0.1.14", 4000)

# List all nodes
Examples.ClusterManager.list_nodes()

# Remove a node
Examples.ClusterManager.remove_node("node-4")
```

## Monitoring Integration

### Prometheus Metrics Exporter

```elixir
defmodule Examples.PrometheusExporter do
  @moduledoc """
  Exports Shanghai metrics to Prometheus format.
  """

  use Plug.Router

  plug :match
  plug :dispatch

  get "/metrics" do
    metrics = collect_metrics()
    prometheus_output = format_prometheus(metrics)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, prometheus_output)
  end

  defp collect_metrics do
    %{
      wal_writes: collect_wal_metrics(),
      cluster_nodes: collect_cluster_metrics(),
      replication_lag: collect_replication_metrics()
    }
  end

  defp collect_wal_metrics do
    # Simulated metrics - in reality, you'd aggregate from telemetry
    %{
      total_writes: 10_000,
      write_duration_p99: 4.5,
      bytes_written: 1_048_576
    }
  end

  defp collect_cluster_metrics do
    nodes = Cluster.Membership.all_nodes()

    %{
      total: length(nodes),
      up: Enum.count(nodes, &(&1.status == :up)),
      down: Enum.count(nodes, &(&1.status == :down))
    }
  end

  defp collect_replication_metrics do
    groups = Replication.all_groups()

    max_lag = Enum.map(groups, & &1.lag) |> Enum.max(fn -> 0 end)

    %{
      max_lag: max_lag,
      groups_count: length(groups)
    }
  end

  defp format_prometheus(metrics) do
    """
    # HELP shanghai_wal_writes_total Total WAL writes
    # TYPE shanghai_wal_writes_total counter
    shanghai_wal_writes_total #{metrics.wal_writes.total_writes}

    # HELP shanghai_wal_write_duration_p99 P99 write duration in ms
    # TYPE shanghai_wal_write_duration_p99 gauge
    shanghai_wal_write_duration_p99 #{metrics.wal_writes.write_duration_p99}

    # HELP shanghai_cluster_nodes_total Total cluster nodes
    # TYPE shanghai_cluster_nodes_total gauge
    shanghai_cluster_nodes_total #{metrics.cluster_nodes.total}

    # HELP shanghai_cluster_nodes_up Nodes in up state
    # TYPE shanghai_cluster_nodes_up gauge
    shanghai_cluster_nodes_up #{metrics.cluster_nodes.up}

    # HELP shanghai_replication_lag_max Maximum replication lag
    # TYPE shanghai_replication_lag_max gauge
    shanghai_replication_lag_max #{metrics.replication_lag.max_lag}
    """
  end
end
```

### Telemetry Handler for Logging

```elixir
defmodule Examples.TelemetryLogger do
  require Logger

  def attach do
    events = [
      [:shanghai, :wal, :write, :completed],
      [:shanghai, :cluster, :heartbeat, :completed],
      [:shanghai, :replication, :lag, :changed]
    ]

    :telemetry.attach_many(
      "telemetry-logger",
      events,
      &handle_event/4,
      nil
    )
  end

  def handle_event([:shanghai, :wal, :write, :completed], measurements, metadata, _config) do
    if measurements.duration > 10 do
      Logger.warning("Slow WAL write",
        duration_ms: measurements.duration,
        bytes: measurements.bytes,
        segment: metadata.segment_id
      )
    end
  end

  def handle_event([:shanghai, :cluster, :heartbeat, :completed], measurements, metadata, _config) do
    if measurements.rtt > 50 do
      Logger.info("High heartbeat RTT",
        rtt_ms: measurements.rtt,
        from: metadata.from_node,
        to: metadata.to_node
      )
    end
  end

  def handle_event([:shanghai, :replication, :lag, :changed], measurements, metadata, _config) do
    if measurements.lag > 1000 do
      Logger.error("High replication lag",
        lag: measurements.lag,
        follower: metadata.follower,
        leader: metadata.leader
      )
    end
  end
end
```

**Usage:**

```elixir
# Attach telemetry handler
Examples.TelemetryLogger.attach()

# Now all telemetry events will be logged
```

## Testing Patterns

### Testing WAL Operations

```elixir
defmodule Examples.WALTest do
  use ExUnit.Case

  alias Storage.WAL.Writer

  setup do
    # Each test gets a clean state
    :ok
  end

  test "writing to WAL returns LSN" do
    data = "test data"
    assert {:ok, lsn} = Writer.append(data)
    assert is_integer(lsn)
    assert lsn > 0
  end

  test "concurrent writes succeed" do
    tasks =
      1..100
      |> Enum.map(fn i ->
        Task.async(fn ->
          data = "data-#{i}"
          Writer.append(data)
        end)
      end)

    results = Task.await_many(tasks)

    # All writes should succeed
    assert Enum.all?(results, fn
      {:ok, _lsn} -> true
      _ -> false
    end)

    # LSNs should be unique
    lsns = Enum.map(results, fn {:ok, lsn} -> lsn end)
    assert length(Enum.uniq(lsns)) == 100
  end
end
```

### Testing Cluster Membership

```elixir
defmodule Examples.MembershipTest do
  use ExUnit.Case

  alias Cluster.Membership
  alias Cluster.Entities.Node
  alias CoreDomain.Types.NodeId

  test "adding node to cluster" do
    node = Node.new(
      node_id: NodeId.new("test-node"),
      host: "localhost",
      port: 4001
    )

    assert :ok = Membership.join_node(node)

    # Verify node in membership
    {:ok, retrieved} = Membership.get_node(NodeId.new("test-node"))
    assert retrieved.id.value == "test-node"
  end

  test "removing node from cluster" do
    node = Node.new(
      node_id: NodeId.new("test-node-2"),
      host: "localhost",
      port: 4002
    )

    :ok = Membership.join_node(node)
    :ok = Membership.leave_node(NodeId.new("test-node-2"))

    # Verify node removed
    assert {:error, :not_found} = Membership.get_node(NodeId.new("test-node-2"))
  end
end
```

## See Also

- [Getting Started Guide](GETTING_STARTED.md)
- [API Reference](API.md)
- [Architecture](ARCHITECTURE.md)
- [Performance Tuning](TUNING.md)
