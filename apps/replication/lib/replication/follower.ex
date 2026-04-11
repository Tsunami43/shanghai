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

  alias CoreDomain.Types.NodeId
  alias Replication.ValueObjects.ReplicationOffset
  alias Storage.WAL.Writer

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
        # Apply the replicated entry to the local WAL when it is running; without
        # a WAL the follower only advances its in-memory offset (test mode).
        case persist_to_wal(data) do
          :ok ->
            Logger.debug("Follower applying entry at offset #{offset.value}")

            # Update current offset
            updated_state = %{state | current_offset: offset}

            # Make applied replication observable, then report to leader and monitor.
            Observability.Metrics.replica_applied(offset.value, state.group_id, state.node_id)
            report_to_leader(updated_state)
            report_to_monitor(updated_state)

            {:noreply, updated_state}

          {:error, reason} ->
            Logger.error(
              "Follower failed to persist entry at offset #{offset.value}: #{inspect(reason)}"
            )

            # Do not advance; the entry will be retried via catch-up.
            {:noreply, state}
        end

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
        Logger.debug(
          "Ignoring old entry at offset #{offset.value}, current is #{state.current_offset.value}"
        )

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

  # Persists a replicated entry to the storage WAL when it is running; a no-op
  # otherwise so replication still works in in-memory (test) mode.
  defp persist_to_wal(data) do
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
    Logger.debug("Follower #{state.node_id.value} reporting offset #{state.current_offset.value}")

    # Report to the leader on its own node: a local cast when the leader is us (or
    # its node is unknown — single-node/test), an `:rpc.cast` to the leader's node
    # otherwise so a remote follower's acks reach the leader's quorum tracking.
    report_offset_to(
      leader_node(state.leader_node_id),
      state.group_id,
      state.node_id,
      state.current_offset
    )

    :ok
  end

  # Resolves the leader's Erlang node from the cluster, or `nil` when unknown.
  defp leader_node(leader_node_id) do
    if Process.whereis(Cluster.Membership) do
      case Cluster.Membership.get_node(leader_node_id) do
        {:ok, node} -> Cluster.Entities.Node.erlang_node_name(node)
        _ -> nil
      end
    else
      nil
    end
  end

  defp report_offset_to(target, group_id, follower_id, offset) when target in [nil, node()] do
    Replication.Leader.report_offset(group_id, follower_id, offset)
  catch
    :exit, _ -> :ok
  end

  defp report_offset_to(target, group_id, follower_id, offset) do
    :rpc.cast(target, Replication.Leader, :report_offset, [group_id, follower_id, offset])
  end

  defp request_catch_up(state) do
    Logger.info(
      "Follower #{state.node_id.value} requesting catch-up from offset #{state.current_offset.value}"
    )

    # The Stream runs on the leader's node, so send the request there (an
    # `:rpc.cast`), falling back to a local cast when the leader is us/unknown.
    request_catch_up_to(
      leader_node(state.leader_node_id),
      state.group_id,
      state.node_id,
      state.current_offset
    )

    :ok
  end

  defp request_catch_up_to(target, group_id, follower_id, offset) when target in [nil, node()] do
    Replication.Stream.request_catch_up(group_id, follower_id, offset)
  catch
    :exit, _ -> :ok
  end

  defp request_catch_up_to(target, group_id, follower_id, offset) do
    :rpc.cast(target, Replication.Stream, :request_catch_up, [group_id, follower_id, offset])
  end

  defp report_to_monitor(state) do
    try do
      Replication.Monitor.record_follower_offset(
        state.group_id,
        state.node_id,
        state.current_offset
      )
    catch
      :exit, _ -> :ok
    end

    :ok
  end
end
