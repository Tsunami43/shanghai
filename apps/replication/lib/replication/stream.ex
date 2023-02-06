defmodule Replication.Stream do
  @moduledoc """
  GenServer managing WAL streaming for a replica group.

  The Stream process is responsible for:
  - Receiving entries from the leader
  - Batching entries for efficient transmission
  - Broadcasting entries to all followers
  - Managing streaming state per follower
  - Detecting and handling slow followers
  """

  use GenServer
  require Logger

  alias Replication.ValueObjects.ReplicationOffset
  alias CoreDomain.Types.NodeId

  @type follower_state :: %{
          node_id: NodeId.t(),
          last_sent_offset: ReplicationOffset.t(),
          last_ack_offset: ReplicationOffset.t(),
          connection_status: :connected | :disconnected
        }

  @type state :: %{
          group_id: String.t(),
          leader_node_id: NodeId.t(),
          followers: %{NodeId.t() => follower_state()},
          pending_entries: :queue.queue(),
          batch_size: pos_integer(),
          flush_interval_ms: pos_integer()
        }

  @default_batch_size 100
  @default_flush_interval_ms 50

  # Client API

  @doc """
  Starts the Stream process for a replica group.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    group_id = Keyword.fetch!(opts, :group_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(group_id))
  end

  @doc """
  Adds an entry to be streamed to followers.
  """
  @spec append_entry(String.t(), ReplicationOffset.t(), binary()) :: :ok
  def append_entry(group_id, offset, data) do
    GenServer.cast(via_tuple(group_id), {:append_entry, offset, data})
  end

  @doc """
  Registers a follower for streaming.
  """
  @spec add_follower(String.t(), NodeId.t()) :: :ok
  def add_follower(group_id, follower_node_id) do
    GenServer.cast(via_tuple(group_id), {:add_follower, follower_node_id})
  end

  @doc """
  Removes a follower from streaming.
  """
  @spec remove_follower(String.t(), NodeId.t()) :: :ok
  def remove_follower(group_id, follower_node_id) do
    GenServer.cast(via_tuple(group_id), {:remove_follower, follower_node_id})
  end

  @doc """
  Gets the streaming state for all followers.
  """
  @spec get_follower_states(String.t()) :: %{NodeId.t() => follower_state()}
  def get_follower_states(group_id) do
    GenServer.call(via_tuple(group_id), :get_follower_states)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    group_id = Keyword.fetch!(opts, :group_id)
    leader_node_id = Keyword.get(opts, :leader_node_id, get_local_node_id())
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    flush_interval_ms = Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms)

    state = %{
      group_id: group_id,
      leader_node_id: leader_node_id,
      followers: %{},
      pending_entries: :queue.new(),
      batch_size: batch_size,
      flush_interval_ms: flush_interval_ms
    }

    # Schedule periodic flush
    schedule_flush(flush_interval_ms)

    Logger.info("Stream started for group #{group_id} on leader #{leader_node_id.value}")

    {:ok, state}
  end

  @impl true
  def handle_cast({:append_entry, offset, data}, state) do
    entry = {offset, data}
    updated_queue = :queue.in(entry, state.pending_entries)
    updated_state = %{state | pending_entries: updated_queue}

    # If batch is full, flush immediately
    queue_length = :queue.len(updated_queue)

    if queue_length >= state.batch_size do
      updated_state = flush_entries(updated_state)
      {:noreply, updated_state}
    else
      {:noreply, updated_state}
    end
  end

  @impl true
  def handle_cast({:add_follower, follower_node_id}, state) do
    follower_state = %{
      node_id: follower_node_id,
      last_sent_offset: ReplicationOffset.zero(),
      last_ack_offset: ReplicationOffset.zero(),
      connection_status: :connected
    }

    updated_followers = Map.put(state.followers, follower_node_id, follower_state)

    Logger.info("Added follower #{follower_node_id.value} to stream for group #{state.group_id}")

    {:noreply, %{state | followers: updated_followers}}
  end

  @impl true
  def handle_cast({:remove_follower, follower_node_id}, state) do
    updated_followers = Map.delete(state.followers, follower_node_id)

    Logger.info(
      "Removed follower #{follower_node_id.value} from stream for group #{state.group_id}"
    )

    {:noreply, %{state | followers: updated_followers}}
  end

  @impl true
  def handle_call(:get_follower_states, _from, state) do
    {:reply, state.followers, state}
  end

  @impl true
  def handle_info(:flush, state) do
    updated_state = flush_entries(state)
    schedule_flush(state.flush_interval_ms)
    {:noreply, updated_state}
  end

  # Private Functions

  defp via_tuple(group_id) do
    {:via, Registry, {Replication.Registry, {:stream, group_id}}}
  end

  defp get_local_node_id do
    node_name = node() |> Atom.to_string()
    NodeId.new(node_name)
  end

  defp schedule_flush(interval_ms) do
    Process.send_after(self(), :flush, interval_ms)
  end

  defp flush_entries(%{pending_entries: queue} = state) do
    if :queue.is_empty(queue) do
      state
    else
      # Convert queue to list for processing
      entries = :queue.to_list(queue)

      # Broadcast to all followers
      Enum.each(state.followers, fn {follower_id, follower_state} ->
        send_entries_to_follower(state.group_id, follower_id, follower_state, entries)
      end)

      # Update last_sent_offset for all followers
      last_offset = entries |> List.last() |> elem(0)

      updated_followers =
        Map.new(state.followers, fn {node_id, follower_state} ->
          {node_id, %{follower_state | last_sent_offset: last_offset}}
        end)

      Logger.debug(
        "Flushed #{length(entries)} entries to #{map_size(state.followers)} followers, last_offset=#{last_offset.value}"
      )

      %{state | pending_entries: :queue.new(), followers: updated_followers}
    end
  end

  defp send_entries_to_follower(group_id, follower_id, follower_state, entries) do
    # Filter entries that follower hasn't received yet
    entries_to_send =
      Enum.filter(entries, fn {offset, _data} ->
        ReplicationOffset.compare(offset, follower_state.last_sent_offset) == :gt
      end)

    if length(entries_to_send) > 0 do
      # In real implementation, this would be an RPC call to follower node
      # For now, send to local follower process if it exists
      try do
        Enum.each(entries_to_send, fn {offset, data} ->
          Replication.Follower.apply_entry(group_id, offset, data)
        end)

        Logger.debug(
          "Sent #{length(entries_to_send)} entries to follower #{follower_id.value}"
        )
      catch
        :exit, reason ->
          Logger.warning(
            "Failed to send entries to follower #{follower_id.value}: #{inspect(reason)}"
          )
      end
    end

    :ok
  end
end
