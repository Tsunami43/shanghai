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
| `replicas` | Replication groups and their status |
| `metrics` | Performance and operational metrics |
| `node join <id>` | Add a node to the cluster |
| `node leave <id>` | Remove a node from the cluster |
| `shutdown` | Safely shut down a node |

Commands talk to a node's `admin_api` (see that app for the HTTP surface).
