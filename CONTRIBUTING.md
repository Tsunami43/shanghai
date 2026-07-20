# Contributing to Shanghai

Thanks for your interest in Shanghai, a distributed, replicated log storage
system built on the BEAM. This is a learning/research project; contributions are
welcome.

## Prerequisites

- Elixir `~> 1.16`, Erlang/OTP 26+ (CI runs on Elixir 1.16 / OTP 26.2).
- Fetch dependencies and compile:

```bash
mix deps.get
mix compile
```

## Project layout

Shanghai is an umbrella project with one OTP application per bounded context
under `apps/`:

| App | Responsibility |
|---|---|
| `core_domain` | Shared domain types (LSN, NodeId, LogEntry, Event) |
| `storage` | Write-Ahead Log: segments, index, snapshots, compaction |
| `cluster` | Membership, heartbeat, gossip |
| `replication` | Leader/follower replication, quorum, lag monitoring |
| `query` | User-facing key/value API (`Query`) |
| `observability` | Telemetry, metrics aggregation, structured logging |
| `admin_api` | HTTP admin API and Prometheus `/metrics` |
| `shanghaictl` | Command-line control tool |
| `admin` | Cross-cutting administration (aggregate health) |

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for bounded contexts and the
implementation-status table.

## Before you push

Every change must keep the whole tree green:

```bash
mix compile --warnings-as-errors   # no warnings
mix test                           # all apps
mix format --check-formatted       # formatting
mix credo --strict                 # linting
```

The `mix quality` alias runs format/credo/dialyzer together; `mix test.all`
runs every app's tests.

**Testing durability on a real disk.** Tests write under `System.tmp_dir!/0`
(`/tmp`), which is tmpfs on most Linux systems - there an `fsync` is a memory
barrier, not a disk flush, so crash-recovery and group-commit tests do not
exercise real durability. `mix test.disk` runs the whole suite against a real
filesystem (`./tmp/test` by default, or `SHANGHAI_TEST_DIR`) by pointing
`TMPDIR` at it. Run it when touching the WAL, fsync, recovery, or epoch
persistence. Confirm the target is not tmpfs with `df -T`.

- **English only.** All repository content (code, comments, docstrings, commit
  messages, and documentation) must be in English. CI enforces this.
- **Keep docs honest.** When you change behavior, update the relevant docs so
  they match the code (config keys, telemetry event names, protocol specs).

## Testing conventions

- Prefer `start_supervised!/1` for the WAL singletons
  (`Storage.WAL.Writer`/`Reader`/`SegmentIndex`) so teardown is deterministic and
  the named processes don't leak across test modules.
- The `cluster` app omits its `mod:` callback under `MIX_ENV=test`; a suite that
  needs a live cluster starts `Cluster.Application` explicitly.
- `Replication.Monitor` is disabled under the test env (`config/test.exs`);
  start it explicitly when a suite needs it.

## Commit messages

Use [conventional commits](https://www.conventionalcommits.org/):
`type(scope): summary`, e.g. `feat(query): add compare-and-swap`. Keep each
commit atomic and green.
