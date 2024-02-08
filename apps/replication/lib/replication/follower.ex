defmodule Replication.Follower do
  @moduledoc """
  GenServer managing follower responsibilities for a replica group.

  The Follower process is responsible for:
  - Receiving replicated entries from leader
  - Applying entries to local WAL
  - Reporting offset progress to leader
  - Detecting and handling lag
  """

  use GenServer
  require Logger

  alias Replication.ValueObjects.ReplicationOffset
  alias CoreDomain.Types.NodeId

  @type state :: %{
          group_id: String.t(),
          node_id: NodeId.t(),
          leader_node_id: NodeId.t() | nil,
          current_offset: ReplicationOffset.t(),
          last_report_at: integer()
        }

  @report_interval_ms 1000

  # Client API

  @doc """
  Starts the Follower process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    group_id = Keyword.fetch!(opts, :group_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(group_id))
  end

  @doc """
  Applies a replicated entry from the leader.
  """
  @spec apply_entry(String.t(), ReplicationOffset.t(), binary()) :: :ok
  def apply_entry(group_id, offset, data) do
    GenServer.cast(via_tuple(group_id), {:apply_entry, offset, data})
  end

  @doc """
  Gets the current follower offset.
  """
  @spec current_offset(String.t()) :: ReplicationOffset.t()
  def current_offset(group_id) do
    GenServer.call(via_tuple(group_id), :current_offset)
  end

  @doc """
  Sets the leader for this follower.
  """
  @spec set_leader(String.t(), NodeId.t()) :: :ok
  def set_leader(group_id, leader_node_id) do
    GenServer.cast(via_tuple(group_id), {:set_leader, leader_node_id})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    group_id = Keyword.fetch!(opts, :group_id)
    node_id = Keyword.get(opts, :node_id, get_local_node_id())
    leader_node_id = Keyword.get(opts, :leader_node_id)

    state = %{
      group_id: group_id,
      node_id: node_id,
      leader_node_id: leader_node_id,
      current_offset: ReplicationOffset.zero(),
      last_report_at: System.monotonic_time(:millisecond)
    }

    # Schedule periodic offset reporting
    schedule_report()

    Logger.info("Follower started for group #{group_id} on node #{node_id.value}")

    {:ok, state}
  end

  @impl true
  def handle_cast({:apply_entry, offset, data}, state) do
    # Verify offset is the next expected one
    expected_offset = ReplicationOffset.increment(state.current_offset)

    cond do
      ReplicationOffset.compare(offset, expected_offset) == :eq ->
        # Apply entry to local storage (in real implementation)
        Logger.debug("Follower applying entry at offset #{offset.value}")

        # Update current offset
        updated_state = %{state | current_offset: offset}

        # Immediately report to leader if this is a new offset
        report_to_leader(updated_state)

        {:noreply, updated_state}

      ReplicationOffset.compare(offset, expected_offset) == :gt ->
        # Gap detected - entries were skipped
        Logger.warning(
          "Gap detected: expected #{expected_offset.value}, got #{offset.value}. Requesting catch-up."
        )

        # Request catch-up from current offset
        request_catch_up(state)

        {:noreply, state}

      true ->
        # Received old entry, ignore
        Logger.debug("Ignoring old entry at offset #{offset.value}, current is #{state.current_offset.value}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:set_leader, leader_node_id}, state) do
    Logger.info("Follower #{state.node_id.value} now following #{leader_node_id.value}")

    updated_state = %{state | leader_node_id: leader_node_id}

    # Report current offset to new leader
    report_to_leader(updated_state)

    {:noreply, updated_state}
  end

  @impl true
  def handle_call(:current_offset, _from, state) do
    {:reply, state.current_offset, state}
  end

  @impl true
  def handle_info(:report_offset, state) do
    report_to_leader(state)
    schedule_report()
    {:noreply, state}
  end

  # Private Functions

  defp via_tuple(group_id) do
    {:via, Registry, {Replication.Registry, {:follower, group_id}}}
  end

  defp get_local_node_id do
    node_name = node() |> Atom.to_string()
    NodeId.new(node_name)
  end

  defp schedule_report do
    Process.send_after(self(), :report_offset, @report_interval_ms)
  end

  defp report_to_leader(%{leader_node_id: nil} = _state) do
    # No leader yet, skip reporting
    :ok
  end

  defp report_to_leader(state) do
    # Report current offset to leader
    # In real implementation, this would be an RPC call to leader node
    Logger.debug(
      "Follower #{state.node_id.value} reporting offset #{state.current_offset.value}"
    )

    # Try to report to local leader process if it exists
    try do
      Replication.Leader.report_offset(
        state.group_id,
        state.node_id,
        state.current_offset
      )
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp request_catch_up(state) do
    # Request catch-up from stream
    # In real implementation, this would be an RPC call to leader/stream on leader node
    Logger.info(
      "Follower #{state.node_id.value} requesting catch-up from offset #{state.current_offset.value}"
    )

    try do
      Replication.Stream.request_catch_up(
        state.group_id,
        state.node_id,
        state.current_offset
      )
    catch
      :exit, reason ->
        Logger.warning("Failed to request catch-up: #{inspect(reason)}")
        :ok
    end

    :ok
  end
end
