# Shanghai Integration Guide

This guide shows how to integrate Shanghai into your Elixir application as a distributed data layer.

## Table of Contents

- [Overview](#overview)
- [Installation](#installation)
- [Basic Integration](#basic-integration)
- [Use Cases](#use-cases)
- [Client Libraries](#client-libraries)
- [Best Practices](#best-practices)
- [Migration Strategies](#migration-strategies)

## Overview

Shanghai can be integrated into your application in several ways:

1. **Embedded mode**: Shanghai runs in same BEAM VM as your app
2. **Client mode**: Your app connects to Shanghai cluster via RPC
3. **HTTP mode**: Your app uses Admin API over HTTP

### When to Use Shanghai

✅ **Good fit:**
- Event sourcing / CQRS applications
- Audit logging and compliance
- Change data capture (CDC)
- Distributed messaging
- Replicated state machines

❌ **Not a good fit:**
- Complex queries (use PostgreSQL)
- Document storage (use MongoDB)
- Key-value with TTL (use Redis)
- Full-text search (use Elasticsearch)

## Installation

### Add Dependency

In your `mix.exs`:

```elixir
def deps do
  [
    # Use Shanghai as a library
    {:shanghai, "~> 1.2"}

    # Or from GitHub
    # {:shanghai, github: "yourorg/shanghai", tag: "v1.2.0"}
  ]
end
```

### Fetch Dependencies

```bash
mix deps.get
mix compile
```

## Basic Integration

### Embedded Mode

Run Shanghai in the same VM as your application.

#### 1. Add to Supervision Tree

In `lib/my_app/application.ex`:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Your application children
      MyApp.Repo,
      MyAppWeb.Endpoint,

      # Shanghai components
      {Cluster.Membership, node_id: "myapp-node-1"},
      {Cluster.Heartbeat, []},
      {Storage.WAL.Writer, data_dir: "/var/lib/myapp/wal"},
      {Storage.WAL.BatchWriter, []},

      # Your app-specific Shanghai integrations
      MyApp.EventStore
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

#### 2. Configure

In `config/config.exs`:

```elixir
config :shanghai,
  node_id: System.get_env("NODE_ID") || "node-1"

config :storage,
  data_dir: System.get_env("SHANGHAI_DATA_DIR") || "/var/lib/myapp/wal",
  segment_size_threshold: 64 * 1024 * 1024

config :cluster,
  heartbeat_interval_ms: 5_000,
  suspect_timeout_ms: 10_000,
  down_timeout_ms: 15_000
```

### Client Mode

Connect to remote Shanghai cluster.

#### 1. Start Distributed Erlang

```bash
iex --name myapp@127.0.0.1 --cookie shanghai_cookie -S mix
```

#### 2. Connect to Cluster

```elixir
# In your application
Node.connect(:"shanghai1@10.0.1.10")
Node.connect(:"shanghai2@10.0.1.11")
```

#### 3. Use Remote APIs

```elixir
# Write to remote Shanghai cluster
data = :erlang.term_to_binary(%{event: "user_signup"})
{:ok, lsn} = :rpc.call(
  :"shanghai1@10.0.1.10",
  Storage.WAL.Writer,
  :append,
  [data]
)
```

## Use Cases

### Event Sourcing

Store domain events in Shanghai WAL.

```elixir
defmodule MyApp.EventStore do
  use GenServer
  alias Storage.WAL.Writer

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def append_event(stream_id, event_type, data, metadata \\\\ %{}) do
    GenServer.call(__MODULE__, {:append, stream_id, event_type, data, metadata})
  end

  def read_stream(stream_id, start_version \\\\ 0) do
    GenServer.call(__MODULE__, {:read_stream, stream_id, start_version})
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    state = %{
      streams: %{},  # stream_id => [lsns]
      events: %{}    # lsn => event
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:append, stream_id, event_type, data, metadata}, _from, state) do
    event = %{
      stream_id: stream_id,
      event_type: event_type,
      data: data,
      metadata: metadata,
      timestamp: System.system_time(:millisecond),
      version: get_next_version(state, stream_id)
    }

    event_bytes = :erlang.term_to_binary(event)

    case Writer.append(event_bytes) do
      {:ok, lsn} ->
        # Update stream index
        new_streams = Map.update(
          state.streams,
          stream_id,
          [lsn],
          &([lsn | &1])
        )

        # Cache event
        new_events = Map.put(state.events, lsn, event)

        new_state = %{state | streams: new_streams, events: new_events}
        {:reply, {:ok, lsn, event.version}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:read_stream, stream_id, start_version}, _from, state) do
    lsns = Map.get(state.streams, stream_id, [])

    events =
      lsns
      |> Enum.reverse()
      |> Enum.map(&Map.get(state.events, &1))
      |> Enum.filter(&(&1 && &1.version >= start_version))

    {:reply, {:ok, events}, state}
  end

  defp get_next_version(state, stream_id) do
    lsns = Map.get(state.streams, stream_id, [])
    length(lsns) + 1
  end
end
```

**Usage:**

```elixir
# Append events
MyApp.EventStore.append_event(
  "user-123",
  :user_registered,
  %{email: "user@example.com", name: "John Doe"}
)

MyApp.EventStore.append_event(
  "user-123",
  :email_verified,
  %{verified_at: DateTime.utc_now()}
)

# Read stream
{:ok, events} = MyApp.EventStore.read_stream("user-123")
```

### Audit Logging

Store audit trail for compliance.

```elixir
defmodule MyApp.AuditLog do
  alias Storage.WAL.Writer

  def log_action(user_id, action, resource, metadata \\\\ %{}) do
    entry = %{
      type: :audit_log,
      user_id: user_id,
      action: action,
      resource: resource,
      metadata: metadata,
      timestamp: DateTime.utc_now(),
      node: Node.self()
    }

    entry_bytes = :erlang.term_to_binary(entry)

    case Writer.append(entry_bytes) do
      {:ok, lsn} ->
        Logger.info("Audit log written",
          user_id: user_id,
          action: action,
          lsn: lsn
        )
        {:ok, lsn}

      {:error, reason} ->
        Logger.error("Audit log failed",
          user_id: user_id,
          reason: reason
        )
        {:error, reason}
    end
  end
end
```

**Usage:**

```elixir
MyApp.AuditLog.log_action(
  "user-123",
  :delete_account,
  "account-456",
  %{reason: "user_request", ip: "192.168.1.1"}
)
```

### Change Data Capture

Capture database changes to WAL.

```elixir
defmodule MyApp.CDC do
  @moduledoc """
  Captures changes to Ecto models and writes to Shanghai.
  """

  alias Storage.WAL.Writer

  def after_insert(%model{} = record) do
    capture_change(:insert, model, record)
  end

  def after_update(%model{} = record) do
    capture_change(:update, model, record)
  end

  def after_delete(%model{} = record) do
    capture_change(:delete, model, record)
  end

  defp capture_change(operation, model, record) do
    change = %{
      type: :cdc_event,
      operation: operation,
      table: model.__schema__(:source),
      record: serialize(record),
      timestamp: DateTime.utc_now()
    }

    change_bytes = :erlang.term_to_binary(change)
    Writer.append(change_bytes)
  end

  defp serialize(record) do
    record
    |> Map.from_struct()
    |> Map.drop([:__meta__])
  end
end
```

**Usage in Ecto schema:**

```elixir
defmodule MyApp.User do
  use Ecto.Schema

  schema "users" do
    field :email, :string
    field :name, :string
    timestamps()
  end

  # Capture changes
  after_insert &MyApp.CDC.after_insert/1
  after_update &MyApp.CDC.after_update/1
  after_delete &MyApp.CDC.after_delete/1
end
```

## Client Libraries

### Elixir Client

Use Shanghai directly from Elixir.

```elixir
# Already shown in examples above
alias Storage.WAL.Writer
Writer.append(data)
```

### HTTP Client (Any Language)

Use Admin API from any language.

**Python example:**

```python
import requests
import msgpack

class ShanghaiClient:
    def __init__(self, base_url):
        self.base_url = base_url

    def write(self, data):
        # Note: Admin API doesn't expose writes in v1.0
        # Use Erlang RPC instead
        pass

    def get_status(self):
        response = requests.get(f"{self.base_url}/api/v1/status")
        return response.json()

    def get_replicas(self):
        response = requests.get(f"{self.base_url}/api/v1/replicas")
        return response.json()

# Usage
client = ShanghaiClient("http://localhost:9090")
status = client.get_status()
print(f"Cluster state: {status['cluster_state']}")
```

### Future: gRPC Client

v2.0 will include gRPC API for efficient cross-language access.

## Best Practices

### 1. Serialize Data Properly

Use Erlang Term Format (ETF) for Elixir, MessagePack or Protocol Buffers for other languages.

**Elixir:**
```elixir
data = :erlang.term_to_binary(%{user_id: 123, action: :login})
Storage.WAL.Writer.append(data)
```

**Python (msgpack):**
```python
import msgpack
data = msgpack.packb({"user_id": 123, "action": "login"})
# Send via HTTP/gRPC
```

### 2. Include Metadata

Always include contextual metadata:

```elixir
event = %{
  # Core data
  type: :user_action,
  user_id: user_id,
  action: action,

  # Metadata
  timestamp: System.system_time(:millisecond),
  correlation_id: get_correlation_id(),
  node: Node.self(),
  version: 1
}
```

### 3. Handle Write Failures

```elixir
case Storage.WAL.Writer.append(data) do
  {:ok, lsn} ->
    # Success path
    handle_success(lsn)

  {:error, :disk_full} ->
    # Alert operator
    alert("Disk full!")
    # Retry later or fail request
    {:error, :unavailable}

  {:error, reason} ->
    # Log and retry
    Logger.error("Write failed: #{reason}")
    retry_write(data)
end
```

### 4. Use Batching for High Throughput

For >1000 writes/sec, use BatchWriter:

```elixir
# Instead of Writer
Storage.WAL.BatchWriter.append(data)
```

### 5. Monitor Integration Points

```elixir
:telemetry.attach(
  "myapp-shanghai-monitor",
  [:shanghai, :wal, :write, :completed],
  fn _event, measurements, _metadata, _config ->
    if measurements.duration > 10 do
      Metrics.increment("myapp.shanghai.slow_writes")
    end
  end,
  nil
)
```

## Migration Strategies

### From PostgreSQL WAL

1. **Dual write period**: Write to both PostgreSQL and Shanghai
2. **Verification**: Compare writes for consistency
3. **Cutover**: Switch reads to Shanghai
4. **Cleanup**: Remove PostgreSQL dependency

```elixir
defmodule Migration.DualWrite do
  def write_event(event) do
    # Write to PostgreSQL
    {:ok, pg_id} = Repo.insert(event)

    # Write to Shanghai
    event_bytes = :erlang.term_to_binary(event)
    {:ok, lsn} = Storage.WAL.Writer.append(event_bytes)

    # Verify
    if pg_id != lsn do
      Logger.warning("ID mismatch: PG=#{pg_id}, Shanghai=#{lsn}")
    end

    {:ok, lsn}
  end
end
```

### From EventStore

1. **Export events**: Dump EventStore to files
2. **Import to Shanghai**: Replay events into WAL
3. **Cutover**: Switch to Shanghai for new writes
4. **Decommission**: Remove EventStore

```elixir
defmodule Migration.FromEventStore do
  def import_events(file_path) do
    file_path
    |> File.stream!()
    |> Stream.map(&Jason.decode!/1)
    |> Stream.each(fn event ->
      event_bytes = :erlang.term_to_binary(event)
      Storage.WAL.Writer.append(event_bytes)
    end)
    |> Stream.run()
  end
end
```

## Testing

### Unit Tests

```elixir
defmodule MyApp.EventStoreTest do
  use ExUnit.Case

  setup do
    # Start Shanghai components in test mode
    start_supervised!(Storage.WAL.Writer)
    start_supervised!(MyApp.EventStore)
    :ok
  end

  test "append and read events" do
    stream_id = "test-stream-#{:rand.uniform(10000)}"

    {:ok, lsn1, v1} = MyApp.EventStore.append_event(
      stream_id,
      :event_a,
      %{data: "a"}
    )

    {:ok, lsn2, v2} = MyApp.EventStore.append_event(
      stream_id,
      :event_b,
      %{data: "b"}
    )

    {:ok, events} = MyApp.EventStore.read_stream(stream_id)

    assert length(events) == 2
    assert Enum.at(events, 0).event_type == :event_a
    assert Enum.at(events, 1).event_type == :event_b
  end
end
```

### Integration Tests

```elixir
defmodule MyApp.ShanghaiIntegrationTest do
  use ExUnit.Case

  @tag :integration
  test "write to Shanghai cluster" do
    # Assumes Shanghai cluster running locally
    data = :erlang.term_to_binary(%{test: true})

    assert {:ok, lsn} = Storage.WAL.Writer.append(data)
    assert is_integer(lsn)
    assert lsn > 0
  end
end
```

## Troubleshooting

### Connection Issues

**Problem:** Can't connect to Shanghai cluster

**Solution:**
```bash
# Check Erlang node connectivity
iex> Node.ping(:"shanghai1@10.0.1.10")
:pong  # ✓ Connected
:pang  # ✗ Not connected

# Check cookie matches
iex> Node.get_cookie()
:shanghai_cookie  # Should match remote nodes
```

### Slow Writes

**Problem:** Write latency >50ms

**Solution:**
1. Check disk I/O: `iostat -x 1`
2. Use BatchWriter for higher throughput
3. Increase batch size: `config :storage, batch_size: 200`

### Memory Growth

**Problem:** BEAM memory increasing over time

**Solution:**
```elixir
# Check process memory
:recon.proc_count(:memory, 10)

# Check if subscriber leak
Cluster.Membership.unsubscribe()
```

## See Also

- [Getting Started Guide](GETTING_STARTED.md)
- [API Reference](API.md)
- [Examples](EXAMPLES.md)
- [Operations Guide](OPERATIONS.md)
