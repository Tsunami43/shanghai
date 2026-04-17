defmodule Replication.GroupCoordinator do
  @moduledoc """
  Keeps a replication group's role on this node consistent with the live cluster
  membership.

  The coordinator subscribes to `Cluster.Membership` and, whenever the set of
  `:up` nodes changes, recomputes the group's effective members and its
  deterministic leader (the smallest member id, the same rule the cluster uses)
  and reconciles this node's role via `Replication.start_group/2`:

  - promotes this node to leader when it becomes the smallest up member (e.g. the
    previous leader went down — a failover),
  - demotes it to a follower when a smaller member comes back up,
  - restarts it as a follower of the new leader after a leader change,
  - stops the group here entirely when this node is no longer a member.

  Membership can be supplied directly for testing via the `:up_nodes` option (a
  list or a zero-arity function returning `[NodeId.t()]`); by default it is read
  from `Cluster.Membership`.
  """

  use GenServer
  require Logger

  alias CoreDomain.Types.NodeId

  @role_opt_keys [:group_id, :this_node, :members, :up_nodes]

  # Client API

  @doc """
  Starts a coordinator for `group_id`.

  Options:
  - `:group_id` - the replication group id (required)
  - `:this_node` - this node's `NodeId.t()` (default: derived from `node()`)
  - `:members` - static allow-list of `NodeId.t()` for the group; effective
    members are this list intersected with the up nodes. Defaults to "all up
    nodes" when omitted.
  - `:up_nodes` - a `[NodeId.t()]` or a zero-arity function returning one, used as
    the membership source (default: `Cluster.Membership`).
  - remaining options are forwarded to `Replication.start_group/2` for the chosen
    role (e.g. `:on_apply`, `:persist_wal`, `:batch_size`, `:replica_count`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    group_id = Keyword.fetch!(opts, :group_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(group_id))
  end

  @doc """
  Forces an immediate reconciliation and returns the resulting role
  (`:leader`, `:follower` or `:none`).
  """
  @spec reconcile(String.t()) :: {:ok, :leader | :follower | :none}
  def reconcile(group_id) do
    GenServer.call(via_tuple(group_id), :reconcile)
  end

  @doc """
  Returns this node's current role in `group_id` as tracked by the coordinator.
  """
  @spec current_role(String.t()) :: :leader | :follower | :none
  def current_role(group_id) do
    GenServer.call(via_tuple(group_id), :current_role)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    group_id = Keyword.fetch!(opts, :group_id)

    state = %{
      group_id: group_id,
      this_node: Keyword.get(opts, :this_node) || local_node_id(),
      allow_list: Keyword.get(opts, :members),
      up_nodes: Keyword.get(opts, :up_nodes),
      role_opts: Keyword.drop(opts, @role_opt_keys),
      role: :none,
      leader_id: nil
    }

    if Process.whereis(Cluster.Membership), do: Cluster.Membership.subscribe()

    {:ok, do_reconcile(state)}
  end

  @impl true
  def handle_call(:reconcile, _from, state) do
    new_state = do_reconcile(state)
    {:reply, {:ok, new_state.role}, new_state}
  end

  @impl true
  def handle_call(:current_role, _from, state) do
    {:reply, state.role, state}
  end

  @impl true
  def handle_info({:cluster_event, _event}, state) do
    {:noreply, do_reconcile(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Reconciliation

  # Recomputes the desired role from the current membership and switches to it
  # when it differs from the role this node currently holds.
  defp do_reconcile(state) do
    members = effective_members(state)
    leader_id = if members == [], do: nil, else: NodeId.min_of(members)
    desired = desired_role(members, leader_id, state.this_node)

    if {desired, leader_id_value(leader_id)} == {state.role, leader_id_value(state.leader_id)} do
      state
    else
      switch_role(state, desired, leader_id, members)
    end
  end

  defp switch_role(state, desired, leader_id, members) do
    # Tear down whatever role this node was running for the group before taking on
    # the new one, so we never run a stale leader/follower alongside the new role.
    Replication.stop_group(state.group_id)

    case desired do
      :none ->
        Logger.info("Coordinator: group #{state.group_id} has no role on this node")

      role ->
        Logger.info("Coordinator: group #{state.group_id} -> #{role} (leader #{leader_id.value})")

        start_role(state, leader_id, members)
    end

    %{state | role: desired, leader_id: leader_id}
  end

  defp start_role(state, leader_id, members) do
    opts =
      state.role_opts
      |> Keyword.put(:members, members)
      |> Keyword.put(:leader_id, leader_id)
      |> Keyword.put(:this_node, state.this_node)

    Replication.start_group(state.group_id, opts)
  end

  defp desired_role(members, leader_id, this_node) do
    cond do
      not Enum.any?(members, &NodeId.equal?(&1, this_node)) -> :none
      NodeId.equal?(this_node, leader_id) -> :leader
      true -> :follower
    end
  end

  # Effective members = the up nodes, optionally narrowed to a static allow-list.
  defp effective_members(state) do
    up = up_node_ids(state.up_nodes)

    case state.allow_list do
      nil -> up
      list -> Enum.filter(list, fn m -> Enum.any?(up, &NodeId.equal?(&1, m)) end)
    end
  end

  defp up_node_ids(nil), do: read_membership_up_nodes()
  defp up_node_ids(fun) when is_function(fun, 0), do: fun.()
  defp up_node_ids(list) when is_list(list), do: list

  defp read_membership_up_nodes do
    if Process.whereis(Cluster.Membership) do
      Cluster.Membership.get_cluster() |> Cluster.State.available_node_ids()
    else
      []
    end
  end

  defp leader_id_value(nil), do: nil
  defp leader_id_value(%NodeId{value: value}), do: value

  defp local_node_id do
    node() |> Atom.to_string() |> NodeId.new()
  end

  defp via_tuple(group_id) do
    {:via, Registry, {Replication.Registry, {:coordinator, group_id}}}
  end
end
