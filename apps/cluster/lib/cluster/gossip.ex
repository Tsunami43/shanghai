defmodule Cluster.Gossip do
  @moduledoc """
  GenServer that implements the gossip protocol for cluster event propagation.

  The Gossip process is responsible for:
  - Broadcasting cluster events to all nodes
  - Receiving and processing gossip messages from other nodes
  - Ensuring eventual consistency of cluster state
  - Managing gossip rounds and fanout
  """

  use GenServer
  require Logger

  alias Cluster.Membership
  alias Cluster.ValueObjects.Heartbeat
  alias CoreDomain.Types.NodeId

  @default_fanout 3
  @default_interval_ms 1_000

  @type message ::
          {:heartbeat, Heartbeat.t()}
          | {:cluster_event, struct()}
          | {:membership_sync, map()}

  @type state :: %{
          fanout: non_neg_integer(),
          interval_ms: non_neg_integer(),
          message_buffer: [message()],
          seen_messages: MapSet.t()
        }

  # Client API

  @doc """
  Starts the Gossip server.

  Options:
  - `:fanout` - Number of nodes to gossip to in each round (default: 3)
  - `:interval_ms` - Gossip interval in milliseconds (default: 1000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Broadcasts a message to the cluster via gossip.
  """
  @spec broadcast(message()) :: :ok
  def broadcast(message) do
    GenServer.cast(__MODULE__, {:broadcast, message})
  end

  @doc """
  Receives a gossip message from another node.
  """
  @spec receive_gossip(node(), message()) :: :ok
  def receive_gossip(from_node, message) do
    GenServer.cast(__MODULE__, {:receive_gossip, from_node, message})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    fanout = Keyword.get(opts, :fanout, @default_fanout)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    state = %{
      fanout: fanout,
      interval_ms: interval_ms,
      message_buffer: [],
      seen_messages: MapSet.new()
    }

    # Schedule first gossip round
    schedule_gossip_round(interval_ms)

    Logger.info("Gossip server started (fanout=#{fanout}, interval=#{interval_ms}ms)")

    {:ok, state}
  end

  @impl true
  def handle_cast({:broadcast, message}, state) do
    message_id = generate_message_id(message)

    # Add to seen messages to avoid processing our own messages
    updated_seen = MapSet.put(state.seen_messages, message_id)

    # Add to buffer for next gossip round
    updated_buffer = [message | state.message_buffer]

    Logger.debug("Broadcasting message via gossip: #{inspect(message)}")

    {:noreply, %{state | message_buffer: updated_buffer, seen_messages: updated_seen}}
  end

  @impl true
  def handle_cast({:receive_gossip, from_node, message}, state) do
    # A gossip round sends a *batch* (the sender's message buffer) in one RPC, so
    # normalize to a list and process each message individually. A single message
    # (List.wrap keeps it a one-element list) works the same way.
    new_state =
      message
      |> List.wrap()
      |> Enum.reduce(state, fn msg, acc -> receive_one(from_node, msg, acc) end)

    {:noreply, new_state}
  end

  defp receive_one(from_node, message, state) do
    message_id = generate_message_id(message)

    if MapSet.member?(state.seen_messages, message_id) do
      Logger.debug("Ignoring duplicate gossip message from #{from_node}")
      state
    else
      process_gossip_message(message)

      Logger.debug("Received gossip message from #{from_node}: #{inspect(message)}")

      %{
        state
        | seen_messages: MapSet.put(state.seen_messages, message_id),
          message_buffer: [message | state.message_buffer]
      }
    end
  end

  @impl true
  def handle_info(:gossip_round, state) do
    # Get random subset of nodes to gossip to
    target_nodes = select_gossip_targets(state.fanout)

    # Send buffered messages to target nodes
    if state.message_buffer != [] and target_nodes != [] do
      Enum.each(target_nodes, fn node ->
        send_gossip_to_node(node, state.message_buffer)
      end)

      Logger.debug(
        "Gossip round: sent #{length(state.message_buffer)} messages to #{length(target_nodes)} nodes"
      )
    end

    # Clear buffer after gossip round
    updated_state = %{state | message_buffer: []}

    # Periodically clean up old seen messages to prevent unbounded growth
    updated_seen = cleanup_seen_messages(state.seen_messages)

    # Schedule next round
    schedule_gossip_round(state.interval_ms)

    {:noreply, %{updated_state | seen_messages: updated_seen}}
  end

  @impl true
  def handle_info({:broadcast_heartbeat, heartbeat}, state) do
    # Handle heartbeat broadcasts from the Heartbeat process
    message = {:heartbeat, heartbeat}
    message_id = generate_message_id(message)

    updated_seen = MapSet.put(state.seen_messages, message_id)
    updated_buffer = [message | state.message_buffer]

    {:noreply, %{state | message_buffer: updated_buffer, seen_messages: updated_seen}}
  end

  # Private Functions

  defp schedule_gossip_round(interval_ms) do
    Process.send_after(self(), :gossip_round, interval_ms)
  end

  defp select_gossip_targets(fanout) do
    gossip_targets(Membership.all_nodes(), Membership.local_node_id(), fanout)
  end

  @doc false
  # Selects up to `fanout` random `:up` peers to gossip to, excluding the local
  # node (gossiping to self is wasted work and re-delivers our own messages).
  @spec gossip_targets([Cluster.Entities.Node.t()], NodeId.t(), non_neg_integer()) :: [
          Cluster.Entities.Node.t()
        ]
  def gossip_targets(nodes, local_id, fanout) do
    nodes
    |> Enum.filter(&(&1.status == :up and &1.id != local_id))
    |> Enum.take_random(fanout)
  end

  defp send_gossip_to_node(node, messages) do
    # Get the Erlang node name for the target
    erlang_node = Cluster.Entities.Node.erlang_node_name(node)

    # Send messages to the gossip process on the target node
    case :rpc.call(erlang_node, __MODULE__, :receive_gossip, [node(), messages]) do
      {:badrpc, reason} ->
        Logger.warning("Failed to gossip to #{erlang_node}: #{inspect(reason)}")

      _ ->
        :ok
    end
  end

  defp process_gossip_message({:heartbeat, heartbeat}) do
    # Forward heartbeat to heartbeat process
    Cluster.Heartbeat.record_heartbeat(heartbeat)
  end

  defp process_gossip_message({:cluster_event, event}) do
    # Apply the peer's membership change to our local view. Idempotent and does
    # not re-emit to gossip, so it cannot loop.
    Logger.debug("Received cluster event via gossip: #{inspect(event)}")
    Membership.apply_remote_event(event)
  end

  defp process_gossip_message({:membership_sync, %{nodes: nodes}}) when is_list(nodes) do
    # Anti-entropy: merge the peer's node list into our view so a node that just
    # joined converges on the current membership, not only future events.
    Logger.debug("Received membership sync via gossip (#{length(nodes)} nodes)")
    Membership.merge_membership(nodes)
  end

  defp process_gossip_message({:membership_sync, _other}) do
    Logger.debug("Received membership sync via gossip (ignored: unexpected shape)")
  end

  defp process_gossip_message(message) do
    Logger.warning("Unknown gossip message type: #{inspect(message)}")
  end

  defp generate_message_id(message) do
    # The id must be a deterministic function of the message *content* only.
    # Distinct messages already differ in content (heartbeats carry a sequence and
    # timestamp; events carry their own timestamp), so hashing the content dedups
    # duplicates while keeping genuinely different messages distinct. Mixing in a
    # call-time clock (as a previous version did) gave the same message a new id on
    # every hash, defeating dedup and causing unbounded re-propagation.
    :erlang.phash2(message)
  end

  defp cleanup_seen_messages(seen_messages) do
    # Keep only the most recent messages to prevent unbounded growth
    # In a real implementation, we'd use a time-based expiration
    if MapSet.size(seen_messages) > 10_000 do
      MapSet.new()
    else
      seen_messages
    end
  end
end
