# Query

User-facing read/write API for Shanghai. `Query` is the composition point that
turns key/value operations into durable, observable storage actions.

## Public API

```elixir
Query.write("user:1", %{name: "Alice"})        #=> {:ok, :written}
Query.read("user:1")                            #=> {:ok, %{name: "Alice"}}
Query.read("missing")                           #=> {:error, :not_found}
Query.delete("user:1")                          #=> {:ok, :deleted}

# Atomic multi-key transaction (single WAL record on a single node)
Query.transact([
  {:write, "account:1", %{balance: 100}},
  {:delete, "account:2"}
])                                              #=> {:ok, :committed}

# Atomic get-and-delete (pop) — useful for queues
Query.take("job:1")                             #=> {:ok, %{...}}  (and removes the key)

# Atomic read-modify-write
Query.update("tags", [], &["new" | &1])         #=> {:ok, ["new", ...]}

# Atomic counter
Query.increment("hits")                         #=> {:ok, 1}   (missing key starts at 0)
Query.increment("hits", 5)                      #=> {:ok, 6}

# Atomic compare-and-swap (optimistic concurrency)
Query.cas("counter", :absent, 1)                #=> {:ok, :swapped}   (only if missing)
Query.cas("counter", 1, 2)                      #=> {:ok, :swapped}   (only if current == 1)
Query.cas("counter", 1, 3)                      #=> {:error, :precondition_failed}

# Collection / range access
Query.mget(["user:1", "user:2", "missing"])     #=> {:ok, %{"user:1" => ..., "user:2" => ...}}
Query.scan("events:order-1:")                   #=> {:ok, [{"events:order-1:1", ...}, ...]}
Query.keys()                                    #=> ["user:1", ...]
Query.count()                                   #=> 42
Query.info()                                    #=> {:ok, %{store: %{durable:, recovered:, size:}, cache: %{...}}}
```

`read/2` and `write/3` accept a `:consistency` option (`:strong` | `:eventual`
| `:causal`); an invalid level returns `{:error, {:invalid_consistency, level}}`.

## Architecture

```
Query  (public API, telemetry, consistency validation)
  ├── Query.Cache   read-through cache (ETS, TTL, bounded, sync invalidation)
  └── Query.Store   materialized KV over the Write-Ahead Log
```

- **`Query.Store`** keeps an in-memory index (ETS memtable) and, when the storage
  WAL is running, write-through appends every mutation for durability. On start
  it replays the WAL to rebuild state — crash recovery for free. Without a
  configured WAL it runs as a fast in-memory KV (e.g. in the test suite).
- **`Query.Cache`** serves reads from ETS; every mutation invalidates the
  affected keys, so a single node never serves a stale read.

## Observability

Every operation emits `[:shanghai, :query, :operation]` with
`%{duration_ms}` measurements and `%{operation, result}` metadata
(`operation ∈ {:read, :write, :delete, :transact, :scan}`).

## Scope

Operations resolve on the local node today. Partition-aware routing, quorum
consistency and cross-node transactions are layered on top of this store in the
replication phase of the roadmap (`docs/ROADMAP_1000.md`).
