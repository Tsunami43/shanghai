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

  alias Replication.ReplicaGroup
  alias Replication.ValueObjects.ReplicationOffset
  alias CoreDomain.Types.NodeId

  @type state :: %{
          group_id: String.t(),
          node_id: NodeId.t(),
          current_offset: ReplicationOffset.t(),
          pending_writes: %{reference() => map()},
          follower_offsets: %{NodeId.t() => ReplicationOffset.t()}
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
  Returns when write is replicated to quorum.
  """
  @spec write(String.t(), binary(), keyword()) :: {:ok, ReplicationOffset.t()} | {:error, atom()}
  def write(group_id, data, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    GenServer.call(via_tuple(group_id), {:write, data}, timeout)
  end

  @doc """
  Gets the current leader offset.
  """
  @spec current_offset(String.t()) :: ReplicationOffset.t()
  def current_offset(group_id) do
    GenServer.call(via_tuple(group_id), :current_offset)
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

    state = %{
      group_id: group_id,
      node_id: node_id,
      current_offset: ReplicationOffset.zero(),
      pending_writes: %{},
      follower_offsets: %{}
    }

    Logger.info("Leader started for group #{group_id} on node #{node_id.value}")

    {:ok, state}
  end

  @impl true
  def handle_call({:write, data}, from, state) do
    # Generate write reference
    write_ref = make_ref()

    # Increment offset
    new_offset = ReplicationOffset.increment(state.current_offset)

    # Store pending write
    pending_write = %{
      ref: write_ref,
      offset: new_offset,
      data: data,
      from: from,
      acks: [state.node_id],
      timestamp: System.monotonic_time(:millisecond)
    }

    updated_pending = Map.put(state.pending_writes, write_ref, pending_write)

    Logger.debug("Leader received write, offset=#{new_offset.value}")

    # Write to local WAL (in real implementation)
    # For now, just track the write

    # Broadcast to followers (will be implemented with Stream)
    broadcast_to_followers(state.group_id, new_offset, data)

    # Check if we already have quorum (single node case)
    updated_state = %{
      state
      | current_offset: new_offset,
        pending_writes: updated_pending
    }

    updated_state = check_quorum_and_reply(updated_state, write_ref)

    {:noreply, updated_state}
  end

  @impl true
  def handle_call(:current_offset, _from, state) do
    {:reply, state.current_offset, state}
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

  # Private Functions

  defp via_tuple(group_id) do
    {:via, Registry, {Replication.Registry, {:leader, group_id}}}
  end

  defp get_local_node_id do
    node_name = node() |> Atom.to_string()
    NodeId.new(node_name)
  end

  defp broadcast_to_followers(group_id, offset, data) do
    # This will be implemented when Stream is added
    # For now, just log
    Logger.debug("Broadcasting offset #{offset.value} to followers of #{group_id}")
    :ok
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
        # Calculate required quorum (majority)
        # In a 3-replica group, need 2 acks
        # For now, assume 1 ack is enough (will be configurable)
        required_acks = 1

        if length(write.acks) >= required_acks do
          # We have quorum, reply to client
          GenServer.reply(write.from, {:ok, write.offset})

          # Remove from pending
          updated_pending = Map.delete(state.pending_writes, write_ref)
          %{state | pending_writes: updated_pending}
        else
          state
        end
    end
  end
end
