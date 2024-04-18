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

# Atomic rename (move value to a new key)
Query.rename("draft:1", "post:1")               #=> {:ok, :renamed} | {:error, :not_found}

# Atomic copy (duplicate value, keep the source)
Query.copy("template", "doc:1")                 #=> {:ok, :copied} | {:error, :not_found}

# Atomic swap (exchange two keys' values)
Query.swap("a", "b")                            #=> {:ok, :swapped} | {:error, :not_found}

# Atomic read-modify-write (upsert with a default)
Query.update("tags", [], &["new" | &1])         #=> {:ok, ["new", ...]}
Query.update_existing("tags", &["x" | &1])      #=> {:ok, [...]} | {:error, :not_found}

# Get-or-compute (race-safe cache fill)
Query.get_or_store("config", fn -> load() end)  #=> {:ok, value}

# Access-style get-and-update (custom return + optional :pop)
Query.get_and_update("counter", fn v -> {v, v + 1} end)  #=> {:ok, old}

# Atomic counter
Query.increment("hits")                         #=> {:ok, 1}   (missing key starts at 0)
Query.increment("hits", 5)                      #=> {:ok, 6}

# Atomic compare-and-swap (optimistic concurrency)
Query.cas("counter", :absent, 1)                #=> {:ok, :swapped}   (only if missing)
Query.cas("counter", 1, 2)                      #=> {:ok, :swapped}   (only if current == 1)
Query.cas("counter", 1, 3)                      #=> {:error, :precondition_failed}
Query.delete_if("lock", "owner-a")              #=> {:ok, :deleted}   (only if current == "owner-a")

# Conditional writes
Query.put_new("user:1", %{})                    #=> {:ok, :written} | {:error, :exists}
Query.replace("user:1", %{})                    #=> {:ok, :written} | {:error, :not_found}
Query.getset("leader", "node-b")                #=> {:ok, "node-a"} | {:ok, :absent}

# Bulk operations (each a single atomic WAL record)
Query.mset(%{"a" => 1, "b" => 2})               #=> {:ok, :committed}
Query.mget(["a", "b", "missing"])               #=> {:ok, %{"a" => 1, "b" => 2}}
Query.mdelete(["a", "b"])                        #=> {:ok, :committed}
Query.delete_prefix("session:1:")               #=> {:ok, {:deleted, 2}}

# Collection / range access
Query.scan("events:order-1:")                   #=> {:ok, [{"events:order-1:1", ...}, ...]}
Query.scan("events:order-1:", limit: 10)        #=> {:ok, [...]}  (paginated)
Query.exists?("user:1")                         #=> true
Query.count_prefix("user:")                     #=> 3
Query.keys()                                    #=> ["user:1", ...]
Query.count()                                   #=> 42
Query.clear()                                   #=> {:ok, :cleared}  (durable, survives restart)
Query.info()                                    #=> {:ok, %{store: %{durable:, recovered:, size:}, cache: %{...}}}

# Ergonomic reads (bare values instead of {:ok, _})
Query.get("user:1")                             #=> %{name: "Alice"} | nil
Query.get("user:1", :none)                      #=> value | :none
Query.get_lazy("cfg", fn -> load() end)         #=> value (fallback computed only on a miss)
Query.fetch!("user:1")                          #=> value | (raises KeyError)
Query.missing(["a", "b", "c"])                  #=> ["b", "c"]  (the absent keys)

# Ordered access
Query.first()                                   #=> {"a", 1} | nil   (smallest key)
Query.last()                                    #=> {"z", 9} | nil   (largest key)
Query.keys_between("b", "d")                    #=> ["b", "c", "d"]
Query.pairs_between("b", "c")                   #=> [{"b", ...}, {"c", ...}]
Query.count_between("b", "d")                   #=> 3
Query.to_map()                                  #=> %{"a" => 1, ...}
Query.to_list()                                 #=> [{"a", 1}, ...]  (sorted by key)

# List values (atomic read-modify-write)
Query.append("items", :a)                       #=> {:ok, [:a]}
Query.prepend("items", :z)                      #=> {:ok, [:z, :a]}
Query.add_to_set("tags", :a)                    #=> {:ok, [:a]}  (no duplicates)
Query.remove_from_list("items", :a)             #=> {:ok, [...]}
Query.pop_first("queue")                        #=> {:ok, elem} | {:ok, nil}
Query.pop_last("stack")                         #=> {:ok, elem} | {:ok, nil}
Query.list_member?("tags", :a)                  #=> true
Query.list_length("items")                      #=> 3

# Map / hash values (atomic read-modify-write)
Query.put_field("user:1", :name, "Alice")       #=> {:ok, %{name: "Alice"}}
Query.merge_fields("user:1", %{age: 30})        #=> {:ok, %{name: "Alice", age: 30}}
Query.increment_field("stats", :hits)           #=> {:ok, %{hits: 1}}
Query.decrement_field("stats", :stock, 2)       #=> {:ok, %{stock: -2}}
Query.rename_field("user:1", :name, :full_name) #=> {:ok, %{full_name: "Alice"}}
Query.pop_field("user:1", :name)                #=> {:ok, "Alice"}
Query.get_field("user:1", :name, "?")           #=> "Alice" | "?"
Query.has_field?("user:1", :name)               #=> true
Query.fields("user:1")                           #=> [:age, :name]  (sorted)
Query.field_count("user:1")                      #=> 2
```

`read/2` and `write/3` accept a `:consistency` option (`:strong` | `:eventual`
| `:causal`), given as an atom or a string (e.g. `"eventual"` from an HTTP
parameter); an invalid level returns `{:error, {:invalid_consistency, level}}`.

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
`%{duration_ms}` measurements and `%{operation, result}` metadata — one event
per public operation (`:read`, `:write`, `:delete`, `:transact`, `:cas`,
`:getset`, `:mset`, `:mdelete`, `:delete_prefix`, and so on).

The read cache tracks hit/miss counters; `Query.info/0` surfaces the
`hit_ratio`, and the cache is tunable via
`config :query, :cache, max_size:, ttl_ms:`.

## Scope

Operations resolve on the local node today. Partition-aware routing, quorum
consistency and cross-node transactions are layered on top of this store in the
replication phase of the roadmap (`docs/ROADMAP_1000.md`).
