defmodule Cluster.LeaderElection do
  @moduledoc """
  Deterministic, leaderless leader election over the current membership view.

  Every node runs this process and independently derives the same answer from the
  same membership: the leader is the `:up` node with the lexicographically
  smallest id (`Cluster.State.deterministic_leader/1`). No votes or consensus
  rounds are needed; agreement follows from a shared, deterministic rule applied
  to a converged membership view.

  The process subscribes to `Cluster.Membership` change events and re-elects
  whenever membership changes. On a leader change it logs and emits the
  `[:shanghai, :cluster, :leader_elected]` telemetry event.
  """

  use GenServer

  require Logger

  alias Cluster.{Membership, State}
  alias CoreDomain.Types.NodeId
  alias Observability.Metrics

  @type t :: %{
          leader: NodeId.t() | nil,
          local_node_id: NodeId.t()
        }

  # Client API

  @doc "Starts the leader-election process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the currently elected leader's node id, or `nil` when none is up."
  @spec leader() :: NodeId.t() | nil
  def leader do
    GenServer.call(__MODULE__, :leader)
  end

  @doc "Returns `true` when the local node is the currently elected leader."
  @spec leader?() :: boolean()
  def leader? do
    GenServer.call(__MODULE__, :is_leader)
  end

  @doc "Returns `true` when `node_id` is the currently elected leader."
  @spec leader?(NodeId.t()) :: boolean()
  def leader?(%NodeId{} = node_id) do
    GenServer.call(__MODULE__, {:is_leader, node_id})
  end

  @doc """
  Recomputes the leader from the current membership synchronously and returns it.
  Normally elections are event-driven; this forces one (useful in tests).
  """
  @spec elect() :: NodeId.t() | nil
  def elect do
    GenServer.call(__MODULE__, :elect)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    Membership.subscribe()

    cluster = Membership.get_cluster()
    leader = State.deterministic_leader(cluster)

    state = %{leader: leader, local_node_id: State.local_node_id(cluster)}

    if leader do
      Logger.info("Leader election initialized: leader=#{leader.value}")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:leader, _from, state) do
    {:reply, state.leader, state}
  end

  def handle_call(:is_leader, _from, state) do
    {:reply, state.leader == state.local_node_id, state}
  end

  def handle_call({:is_leader, node_id}, _from, state) do
    {:reply, state.leader == node_id, state}
  end

  def handle_call(:elect, _from, state) do
    state = reelect(state)
    {:reply, state.leader, state}
  end

  @impl true
  def handle_info({:cluster_event, _event}, state) do
    {:noreply, reelect(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Recomputes the leader; on a change, logs and emits telemetry.
  defp reelect(state) do
    cluster = Membership.get_cluster()
    new_leader = State.deterministic_leader(cluster)

    if new_leader == state.leader do
      state
    else
      Logger.info("Leader changed: #{leader_label(state.leader)} -> #{leader_label(new_leader)}")

      Metrics.leader_elected(State.status_count(cluster, :up), new_leader, state.leader)
      %{state | leader: new_leader}
    end
  end

  defp leader_label(nil), do: "(none)"
  defp leader_label(%NodeId{value: value}), do: value
end
