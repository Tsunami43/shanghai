# shanghaictl

Command-line control tool for operating Shanghai clusters.

## Usage

```
shanghaictl <command> [options]
```

| Command | Description |
|---|---|
| `help` | Show usage |
| `version` | Show version |
| `status` | Cluster status and node health |
| `health` | Node readiness and subsystem checks |
| `info` | Node version and runtime details |
| `config` | Effective runtime configuration |
| `replicas` | Replication groups and their status |
| `metrics` | Performance and operational metrics |
| `storage` | WAL/storage overview |
| `node join <id>` | Add a node to the cluster |
| `node leave <id>` | Remove a node from the cluster |
| `node get <id>` | Show details for a single node |
| `kv get <key>` | Read a value from the store by key |
| `kv count [prefix]` | Count stored keys (optionally under a prefix) |
| `kv keys [prefix]` | List stored keys (optionally under a prefix) |
| `compact` | Trigger a WAL compaction run |
| `snapshot list` | List persisted snapshots |
| `snapshot create` | Create a snapshot at the current LSN |
| `shutdown` | Safely shut down a node |

Commands talk to a node's `admin_api` (see that app for the HTTP surface).

## Admin URL

The Admin API base URL is resolved in order of precedence:

1. `--admin-url URL` (or `--admin-url=URL`) on the command line
2. the `SHANGHAI_ADMIN_URL` environment variable
3. the default `http://localhost:9090`

```bash
export SHANGHAI_ADMIN_URL=http://node-1:9090
shanghaictl status
```
