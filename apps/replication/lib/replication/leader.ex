defmodule Replication.Leader do
  @moduledoc """
  GenServer managing leader responsibilities for a replica group.

  The Leader process is responsible for:
  - Accepting writes from clients
  - Appending entries to local WAL
  - Coordinating replication to followers
  - Tracking acknowledgments for quorum
  - Ensuring write ordering
  """

  use GenServer
  require Logger

  alias CoreDomain.Types.NodeId
  alias Replication.ValueObjects.{ConsistencyLevel, ReplicationOffset}
  alias Storage.WAL.Writer

  @type state :: %{
          group_id: String.t(),
          node_id: NodeId.t(),
          current_offset: ReplicationOffset.t(),
          pending_writes: %{reference() => map()},
          follower_offsets: %{NodeId.t() => ReplicationOffset.t()},
          replica_count: pos_integer(),
          persist_wal: boolean(),
          epoch: non_neg_integer()
        }

  # Client API

  @doc """
  Starts the Leader process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    group_id = Keyword.fetch!(opts, :group_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(group_id))
  end

  @doc """
  Writes an entry through the leader.
  Returns when write satisfies the specified consistency level.

  Options:
  - `:consistency_level` - ConsistencyLevel.t() or atom (:local, :quorum, :leader)
  - `:timeout` - Write timeout in milliseconds (default: 5000)

  Returns:
  - `{:ok, offset}` - Write succeeded at the given offset
  - `{:error, :timeout}` - Timeout waiting for consistency level
  - `{:error, :invalid_consistency_level}` - Invalid consistency level provided
  """
  @spec write(String.t(), term(), keyword()) :: {:ok, ReplicationOffset.t()} | {:error, atom()}
  def write(group_id, data, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)

    with {:ok, consistency_level} <- validate_consistency_level(opts) do
      # The leader enforces the replication `timeout` itself and replies
      # `{:error, :timeout}` when consistency is not met in time. We give the
      # surrounding call a small buffer so the server's clean reply wins the race
      # against the client-side call timeout.
      GenServer.call(
        via_tuple(group_id),
        {:write, data, consistency_level, timeout},
        timeout + 1000
      )
    end
  end

  @doc """
  Gets the current leader offset.
  """
  @spec current_offset(String.t()) :: ReplicationOffset.t()
  def current_offset(group_id) do
    GenServer.call(via_tuple(group_id), :current_offset)
  end

  @doc """
  Returns this leader's log position as `{epoch, offset}`, used by the election
  up-to-date check when a sitting leader stands in a later epoch.
  """
  @spec position(String.t()) :: {non_neg_integer(), ReplicationOffset.t()}
  def position(group_id) do
    GenServer.call(via_tuple(group_id), :position)
  end

  @doc """
  Follower reports its current offset.
  """
  @spec report_offset(String.t(), NodeId.t(), ReplicationOffset.t()) :: :ok
  def report_offset(group_id, follower_id, offset) do
    GenServer.cast(via_tuple(group_id), {:report_offset, follower_id, offset})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    group_id = Keyword.fetch!(opts, :group_id)
    node_id = Keyword.get(opts, :node_id, get_local_node_id())
    replica_count = Keyword.get(opts, :replica_count, 3)

    state = %{
      group_id: group_id,
      node_id: node_id,
      current_offset: ReplicationOffset.zero(),
      pending_writes: %{},
      follower_offsets: %{},
      replica_count: replica_count,
      # When false, the leader does not persist writes to the storage WAL, a
      # higher layer (e.g. the query store) owns durability and the WAL would
      # otherwise hold a duplicate copy of every replicated record.
      persist_wal: Keyword.get(opts, :persist_wal, true),
      # The leadership epoch this leader won. Every entry it writes carries it,
      # and it is the epoch component of this node's log position.
      epoch: Keyword.get(opts, :epoch, 0)
    }

    Logger.info("Leader started for group #{group_id} on node #{node_id.value}")

    {:ok, state}
  end

  @impl true
  def handle_call({:write, data, consistency_level, timeout}, from, state) do
    # Generate write reference
    write_ref = make_ref()

    # Increment offset
    new_offset = ReplicationOffset.increment(state.current_offset)

    # Calculate required acks based on consistency level
    required_acks = ConsistencyLevel.required_acks(consistency_level, state.replica_count)

    # Arm a server-side timeout so a write that never reaches its ack quorum is
    # cleaned up (no leaked pending entry) and the client gets `{:error, :timeout}`.
    timer_ref = Process.send_after(self(), {:write_timeout, write_ref}, timeout)

    # Store pending write
    pending_write = %{
      ref: write_ref,
      offset: new_offset,
      data: data,
      from: from,
      acks: [state.node_id],
      consistency_level: consistency_level,
      required_acks: required_acks,
      timer_ref: timer_ref,
      timestamp: System.monotonic_time(:millisecond)
    }

    updated_pending = Map.put(state.pending_writes, write_ref, pending_write)

    Logger.debug("Leader received write, offset=#{new_offset.value}")

    # Persist to the local WAL for durability before acknowledging, when the WAL
    # is running and this leader owns durability. Without a WAL (or with
    # `persist_wal: false`) the leader keeps only its in-memory replication log.
    case persist_to_wal(state, data) do
      :ok ->
        # Hand the entry to the Stream, which batches it and fans out to followers.
        broadcast_to_followers(state.group_id, new_offset, data)

        # Report leader offset to monitor
        report_to_monitor(state.group_id, new_offset)

        # Check if we already have quorum (single node case)
        updated_state = %{
          state
          | current_offset: new_offset,
            pending_writes: updated_pending
        }

        updated_state = check_quorum_and_reply(updated_state, write_ref)

        {:noreply, updated_state}

      {:error, reason} ->
        Logger.error("Leader failed to persist write to WAL: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:current_offset, _from, state) do
    {:reply, state.current_offset, state}
  end

  def handle_call(:position, _from, state) do
    {:reply, {state.epoch, state.current_offset}, state}
  end

  @impl true
  def handle_cast({:report_offset, follower_id, offset}, state) do
    Logger.debug("Follower #{follower_id.value} reported offset #{offset.value}")

    updated_follower_offsets = Map.put(state.follower_offsets, follower_id, offset)

    # Update acks for pending writes
    updated_state = %{state | follower_offsets: updated_follower_offsets}
    updated_state = update_pending_acks(updated_state, follower_id, offset)

    {:noreply, updated_state}
  end

  @impl true
  def handle_info({:write_timeout, write_ref}, state) do
    case Map.get(state.pending_writes, write_ref) do
      nil ->
        # Already acknowledged and removed; nothing to do.
        {:noreply, state}

      write ->
        Logger.warning(
          "Write at offset #{write.offset.value} timed out " <>
            "(#{length(write.acks)}/#{write.required_acks} acks)"
        )

        GenServer.reply(write.from, {:error, :timeout})
        {:noreply, %{state | pending_writes: Map.delete(state.pending_writes, write_ref)}}
    end
  end

  # Private Functions

  # Cancels a pending write's server-side timeout timer, if still armed.
  defp cancel_write_timer(%{timer_ref: timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_write_timer(_write), do: :ok

  # Appends the write to the storage WAL when it is running; otherwise a no-op
  # so replication still works in in-memory (single-node/test) mode.
  defp persist_to_wal(%{persist_wal: false}, _data), do: :ok

  defp persist_to_wal(%{persist_wal: true}, data) do
    if is_pid(Process.whereis(Writer)) do
      case Writer.append(data) do
        {:ok, _lsn} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp via_tuple(group_id) do
    {:via, Registry, {Replication.Registry, {:leader, group_id}}}
  end

  defp get_local_node_id do
    node_name = node() |> Atom.to_string()
    NodeId.new(node_name)
  end

  defp broadcast_to_followers(group_id, offset, data) do
    # Send to Stream for batched replication
    Replication.Stream.append_entry(group_id, offset, data)
  catch
    :exit, _ ->
      # Stream not available, log warning
      Logger.warning("Stream not available for group #{group_id}")
      :ok
  end

  defp report_to_monitor(group_id, offset) do
    Replication.Monitor.record_leader_offset(group_id, offset)
  catch
    :exit, _ -> :ok
  end

  defp update_pending_acks(state, follower_id, follower_offset) do
    updated_pending =
      Enum.reduce(state.pending_writes, state.pending_writes, fn {ref, write}, acc ->
        # Check if this follower's offset covers this write
        if ReplicationOffset.compare(follower_offset, write.offset) != :lt do
          # Follower has replicated this write
          updated_write = %{write | acks: [follower_id | write.acks]}
          updated_acc = Map.put(acc, ref, updated_write)

          # Check if we now have quorum
          check_quorum_and_reply_state =
            %{state | pending_writes: updated_acc}
            |> check_quorum_and_reply(ref)

          updated_acc = check_quorum_and_reply_state.pending_writes
          updated_acc
        else
          acc
        end
      end)

    %{state | pending_writes: updated_pending}
  end

  defp check_quorum_and_reply(state, write_ref) do
    case Map.get(state.pending_writes, write_ref) do
      nil ->
        state

      write ->
        ack_count = length(write.acks)

        if ack_count >= write.required_acks do
          # We have satisfied consistency requirement, reply to client
          Logger.debug(
            "Write at offset #{write.offset.value} satisfied #{ConsistencyLevel.to_string(write.consistency_level)} (#{ack_count}/#{write.required_acks} acks)"
          )

          cancel_write_timer(write)
          GenServer.reply(write.from, {:ok, write.offset})

          # Remove from pending
          updated_pending = Map.delete(state.pending_writes, write_ref)
          %{state | pending_writes: updated_pending}
        else
          state
        end
    end
  end

  defp validate_consistency_level(opts) do
    level = Keyword.get(opts, :consistency_level, :quorum)

    case level do
      %ConsistencyLevel{} -> {:ok, level}
      atom when is_atom(atom) -> ConsistencyLevel.parse(atom)
      _ -> {:error, :invalid_consistency_level}
    end
  end
end
