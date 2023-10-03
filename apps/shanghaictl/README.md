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
| `replicas` | Replication groups and their status |
| `metrics` | Performance and operational metrics |
| `node join <id>` | Add a node to the cluster |
| `node leave <id>` | Remove a node from the cluster |
| `node get <id>` | Show details for a single node |
| `kv get <key>` | Read a value from the store by key |
| `kv count [prefix]` | Count stored keys (optionally under a prefix) |
| `kv keys [prefix]` | List stored keys (optionally under a prefix) |
| `compact` | Trigger a WAL compaction run |
| `shutdown` | Safely shut down a node |

Commands talk to a node's `admin_api` (see that app for the HTTP surface).
