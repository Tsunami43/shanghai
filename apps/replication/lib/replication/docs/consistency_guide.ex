defmodule Replication.Docs.ConsistencyGuide do
  @moduledoc """
  Guide to consistency levels in Shanghai replication.

  ## Overview

  Shanghai provides three consistency levels that allow applications
  to trade off between consistency, availability, and latency based
  on their specific requirements.

  ## Consistency Levels

  ### :local

  Fastest option with minimal latency. Write completes as soon as
  the leader acknowledges it locally, without waiting for replication.

  **Use when:**
  - Maximum throughput is required
  - Data can be regenerated if lost
  - Latency is critical (caching, sessions)

  **Guarantees:**
  - No durability guarantee
  - Data may be lost on leader failure
  - Fastest possible writes

  **Example:**
      Leader.write(group_id, data, consistency_level: :local)

  ### :leader

  Balanced option providing ordering guarantees. Write completes when
  the leader acknowledges it, ensuring all writes go through a single
  point for strong ordering.

  **Use when:**
  - Write ordering is important
  - Some risk of data loss is acceptable
  - Low latency is desired

  **Guarantees:**
  - Strict write ordering
  - Leader failure may lose recent writes
  - Better than local, faster than quorum

  **Example:**
      Leader.write(group_id, data, consistency_level: :leader)

  ### :quorum (default)

  Strongest durability guarantee. Write completes when a majority
  of replicas (including the leader) have acknowledged it.

  **Use when:**
  - Data durability is critical
  - Consistency is more important than latency
  - Financial or audit data

  **Guarantees:**
  - Survives minority replica failures
  - Ensures data is replicated before acknowledgment
  - Higher latency than local or leader

  **Example:**
      Leader.write(group_id, data, consistency_level: :quorum)

  ## Choosing a Consistency Level

  ### Decision Matrix

  | Use Case | Recommended Level | Rationale |
  |----------|------------------|-----------|
  | User sessions | :local | Ephemeral data, regenerable |
  | Cache entries | :local | Can be recomputed |
  | Event logs | :leader | Ordering matters, some loss OK |
  | Analytics data | :leader | Approximate OK |
  | User profiles | :quorum | Must not lose |
  | Financial transactions | :quorum | Critical data |
  | Configuration | :quorum | Must be durable |

  ## Performance Characteristics

  ### Latency (typical)
  - :local - < 1ms (leader-only)
  - :leader - < 1ms (leader-only)
  - :quorum - 2-10ms (depends on followers)

  ### Durability
  - :local - No guarantee
  - :leader - Single-node durability
  - :quorum - Majority durability

  ### Availability
  - :local - High (leader only)
  - :leader - High (leader only)
  - :quorum - Medium (needs majority)

  ## Mixed Consistency in Applications

  Applications can use different consistency levels for different
  data types within the same system:

      # Critical user data - must be durable
      Leader.write(user_group, user_data, consistency_level: :quorum)

      # Session data - can be lost
      Leader.write(session_group, session_data, consistency_level: :local)

      # Event log - ordering matters
      Leader.write(event_group, event_data, consistency_level: :leader)

  ## Failure Scenarios

  ### Leader Failure

  - :local writes - May be lost if not yet replicated
  - :leader writes - May be lost if not yet replicated
  - :quorum writes - Survive if replicated to majority

  ### Network Partition

  - :local - Available on leader side
  - :leader - Available on leader side
  - :quorum - Available only with majority

  ### Follower Failure

  - :local - No impact
  - :leader - No impact
  - :quorum - May impact writes if majority lost

  ## Best Practices

  1. **Default to :quorum** for unknown criticality
  2. **Use :local sparingly** only for ephemeral data
  3. **Monitor timeouts** to detect quorum issues
  4. **Consider read consistency** (future feature)
  5. **Test failure scenarios** for your consistency choice

  ## Configuration

  Set per-write via options:

      Leader.write(group_id, data,
        consistency_level: :quorum,
        timeout: 5000
      )

  Or parse from configuration:

      level = ConsistencyLevel.parse("quorum")
      Leader.write(group_id, data, consistency_level: level)
  """
end
