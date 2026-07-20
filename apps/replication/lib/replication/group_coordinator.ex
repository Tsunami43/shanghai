defmodule Replication.GroupCoordinator do
  @moduledoc """
  Keeps a replication group's role on this node consistent with the live cluster
  membership.

  The coordinator subscribes to `Cluster.Membership` and, whenever the set of
  `:up` nodes changes, recomputes the group's effective members and its
  deterministic leader (the smallest member id, the same rule the cluster uses)
  and reconciles this node's role via `Replication.start_group/2`:

  - promotes this node to leader when it becomes the smallest up member (e.g. the
    previous leader went down, a failover),
  - demotes it to a follower when a smaller member comes back up,
  - restarts it as a follower of the new leader after a leader change,
  - stops the group here entirely when this node is no longer a member.

  Membership can be supplied directly for testing via the `:up_nodes` option (a
  list or a zero-arity function returning `[NodeId.t()]`); by default it is read
  from `Cluster.Membership`.

  ## No fencing: this is failover, not consensus

  Promotion is a local decision based on this node's current membership view.
  There is no quorum requirement, no term/epoch number and no fencing of the
  previous leader - correctness depends entirely on membership having converged.

  Under a network partition both sides will promote their own smallest member,
  so the group ends up with two leaders that each accept writes, and nothing
  flags the losing side's entries once the partition heals. Use this to recover
  from a node that has actually died, not as a substitute for a consensus
  protocol.

  A member id must equal the short Erlang node name: `Cluster.Membership` maps a
  `:nodedown` back to a member through `Cluster.Entities.Node.erlang_node_name/1`
  (`"\#{id}@\#{host}"`). If the id and the node name disagree, down events match
  no member and failover silently never fires.
  """

  use GenServer
  require Logger

  alias CoreDomain.Types.NodeId

  @role_opt_keys [:group_id, :this_node, :members, :up_nodes, :elect, :refresh_interval_ms]

  @default_refresh_interval_ms 5_000

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
  - `:elect` - a 3-arity function `(group_id, members, candidate)` returning
    `{:ok, epoch}` or `{:error, :no_quorum}`, used instead of running a real
    election (default: `Replication.stand_for_election/3`). Tests use it to
    exercise role reconciliation without a live cluster to vote.
  - `:refresh_interval_ms` - how often to re-subscribe (if not yet subscribed)
    and re-reconcile as a safety net against a missed event or a coordinator that
    started before `Cluster.Membership`. Default `#{@default_refresh_interval_ms}`;
    set to `nil` or `0` to disable.
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

  @doc """
  Returns the group's current leader id as tracked by the coordinator, or `nil`
  when no leader is known (e.g. no members are up).
  """
  @spec leader(String.t()) :: NodeId.t() | nil
  def leader(group_id) do
    GenServer.call(via_tuple(group_id), :leader)
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
      elect: Keyword.get(opts, :elect),
      role_opts: Keyword.drop(opts, @role_opt_keys),
      role: :none,
      leader_id: nil,
      subscribed: false,
      refresh_ms: Keyword.get(opts, :refresh_interval_ms, @default_refresh_interval_ms)
    }

    state = ensure_subscribed(state)
    schedule_refresh(state)

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

  def handle_call(:leader, _from, state) do
    {:reply, state.leader_id, state}
  end

  @impl true
  def handle_info({:cluster_event, _event}, state) do
    {:noreply, do_reconcile(state)}
  end

  def handle_info(:refresh, state) do
    # Safety net: subscribe if we couldn't at init (membership started later) and
    # re-reconcile in case a membership event was missed.
    state = state |> ensure_subscribed() |> do_reconcile()
    schedule_refresh(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Subscribes to membership once it is available; a no-op once subscribed.
  defp ensure_subscribed(%{subscribed: true} = state), do: state

  defp ensure_subscribed(state) do
    if Process.whereis(Cluster.Membership) do
      Cluster.Membership.subscribe()
      %{state | subscribed: true}
    else
      state
    end
  end

  defp schedule_refresh(%{refresh_ms: ms}) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :refresh, ms)
  end

  defp schedule_refresh(_state), do: :ok

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

  # Becoming leader requires winning an election first. The vote runs BEFORE the
  # old role is torn down, so this node still knows its own replication offset
  # and voters can judge whether its log is complete enough to lead.
  defp switch_role(state, :leader, leader_id, members) do
    case stand_for_election(state) do
      {:ok, epoch} ->
        Replication.stop_group(state.group_id)

        Logger.info(
          "Coordinator: group #{state.group_id} -> leader (leader #{leader_id.value}" <>
            epoch_suffix(epoch) <> ")"
        )

        start_role(state, leader_id, members, epoch)
        commit_role(state, :leader, leader_id)

      {:error, :no_quorum} ->
        # Losing the vote means this node cannot know it is the only leader, so
        # it takes no role at all rather than writing unfenced. The next
        # reconcile or refresh tick will try again.
        Replication.stop_group(state.group_id)

        Logger.warning(
          "Coordinator: group #{state.group_id} could not be promoted, no quorum; staying passive"
        )

        commit_role(state, :none, nil)
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

        start_role(state, leader_id, members, nil)
    end

    commit_role(state, desired, leader_id)
  end

  defp commit_role(state, desired, leader_id) do
    Observability.Metrics.replication_role_changed(
      state.group_id,
      desired,
      leader_id_value(leader_id)
    )

    %{state | role: desired, leader_id: leader_id}
  end

  # Fencing needs a fixed group size: a majority is only meaningful against the
  # configured member list. Without one, "members" is just whoever is currently
  # up, and an isolated node would trivially form a majority of itself - so the
  # election is skipped and promotion stays unfenced, as it was before.
  defp stand_for_election(%{allow_list: nil} = state) do
    Logger.warning(
      "Coordinator: group #{state.group_id} has no configured :members, " <>
        "promoting without a quorum (unfenced)"
    )

    {:ok, nil}
  end

  defp stand_for_election(%{elect: elect} = state) when is_function(elect, 3) do
    elect.(state.group_id, state.allow_list, state.this_node)
  end

  defp stand_for_election(state) do
    Replication.stand_for_election(state.group_id, state.allow_list, state.this_node)
  end

  defp epoch_suffix(nil), do: ", unfenced"
  defp epoch_suffix(epoch), do: ", epoch #{epoch}"

  defp start_role(state, leader_id, members, epoch) do
    opts =
      state.role_opts
      |> Keyword.put(:members, members)
      |> Keyword.put(:leader_id, leader_id)
      |> Keyword.put(:this_node, state.this_node)

    opts = if epoch, do: Keyword.put(opts, :epoch, epoch), else: opts

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
