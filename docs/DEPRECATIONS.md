# Deprecation Notices

This document tracks deprecated APIs and features in Shanghai.

## Policy

- **Deprecation**: Feature marked as deprecated with warning logs
- **Removal**: Feature removed in next major version
- **Timeline**: Minimum 6 months between deprecation and removal

## Current Deprecations

### v1.1.0 (Released 2025-02)

No deprecations in this release.

### v1.2.0 (Released 2025-06)

#### Direct Segment Access (Deprecated)

**What**: Direct calls to `Storage.WAL.Segment.append_entry/2`

**Why**: New `BatchWriter` provides better performance. Direct segment
access bypasses batching optimization.

**Migration**:
```elixir
# Before (deprecated)
Storage.WAL.Segment.append_entry(segment_pid, entry)

# After
Storage.WAL.Writer.append(data)
```

**Removal**: v2.0.0 (planned 2026 Q1)

#### Legacy Heartbeat API (Deprecated)

**What**: `Cluster.Heartbeat.send_heartbeat/1` (manual heartbeat)

**Why**: Heartbeats should be automatic. Manual sending can cause
timing issues and is rarely needed.

**Migration**:
```elixir
# Before (deprecated)
Cluster.Heartbeat.send_heartbeat(node_id)

# After
# Heartbeats are automatic, no action needed
```

**Removal**: v2.0.0

## Upcoming Deprecations (v1.3.0 - Planned)

### Manual Replication Offset Management

Currently you can manually set replication offsets. This will be
deprecated in favor of automatic offset tracking.

### Custom Serializer API

The current `Serializer` behavior allows custom implementations.
This will be locked down to built-in ETF serialization only.

## Removed Features

### v1.0.0

Initial release, no removals.

## Migration Guide

### From v1.1 to v1.2

**No breaking changes**. All v1.1 APIs continue to work with
deprecation warnings.

### From v1.2 to v2.0 (Planned)

**Breaking changes**:

1. **Direct Segment Access Removed**
   - Must use `Storage.WAL.Writer`
   - Compile-time error if using deprecated API

2. **Manual Heartbeat Removed**
   - Remove all calls to `send_heartbeat/1`
   - Rely on automatic heartbeats

**Migration steps**:
```bash
# 1. Fix deprecation warnings in v1.2
mix compile --warnings-as-errors

# 2. Run tests
mix test

# 3. Upgrade to v2.0
# Update mix.exs: {:shanghai, "~> 2.0"}
```

## How to Check for Deprecations

### Runtime Warnings

Deprecated APIs emit warning logs:
```
[warning] Storage.WAL.Segment.append_entry/2 is deprecated.
Use Storage.WAL.Writer.append/1 instead.
This API will be removed in v2.0.0
```

### Compile-time Detection

```bash
# Enable warnings
mix compile --force --warnings-as-errors

# Check for deprecation warnings
grep "deprecated" _build/dev/lib/*/ebin/*.beam
```

### Automated Scanning

Use `mix xref` to find deprecated calls:
```bash
mix xref deprecated
```

## Deprecation Checklist

When deprecating an API:

- [ ] Add deprecation notice to this document
- [ ] Add `@deprecated` annotation to module/function
- [ ] Emit warning log on first use
- [ ] Update all internal usages
- [ ] Update documentation with migration guide
- [ ] Announce in CHANGELOG
- [ ] Set removal version (minimum +1 major version)

## Questions?

See [CONTRIBUTING.md](CONTRIBUTING.md) for deprecation policy details.
