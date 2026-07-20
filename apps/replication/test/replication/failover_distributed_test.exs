defmodule Replication.FailoverDistributedTest do
  @moduledoc """
  Group leader failover across real BEAM nodes.

  The in-process coordinator tests drive membership directly; this one kills an
  entire node and relies on the genuine `:nodedown` path - Erlang distribution
  to `Cluster.Membership` to the coordinator's subscription - to promote the
  survivor.

  Excluded by default because it starts peer nodes and needs a running `epmd`.
  Run with:

      mix test --include distributed
  """

  use ExUnit.Case, async: false

  alias CoreDomain.Types.NodeId
  alias Replication.GroupCoordinator

  @moduletag :distributed
  # Peers boot a full application tree, so allow well beyond the default 60s.
  @moduletag timeout: 180_000

  @host ~c"127.0.0.1"

  setup_all do
    ensure_distribution()
    :ok
  end

  # The test node must itself be distributed before it can start peers.
  defp ensure_distribution do
    unless Node.alive?() do
      case :net_kernel.start([:"shanghai_test@127.0.0.1", :longnames]) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, reason} -> flunk("could not start distribution: #{inspect(reason)}")
      end
    end
  end

  defp start_peer(name) do
    args = [~c"-setcookie", Atom.to_charlist(:erlang.get_cookie())]

    {:ok, pid, node} =
      :peer.start_link(%{name: name, host: @host, longnames: true, args: args})

    # Peers start with an empty code path and none of Mix's config, so the
    # build has to be handed over explicitly.
    :erpc.call(node, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:replication])

    {pid, node}
  end

  # The :cluster app carries no `mod:` under MIX_ENV=test, so Membership is
  # started by hand. GenServer.start (not start_link) is deliberate: the erpc
  # handler process exits as soon as the call returns, and a link would take
  # Membership down with it.
  defp start_membership(node, id) do
    {:ok, _} =
      :erpc.call(node, GenServer, :start, [
        Cluster.Membership,
        [node_id: id],
        [name: Cluster.Membership]
      ])
  end

  # A member id MUST equal the short Erlang node name: Membership maps a
  # `:nodedown` back to a member through `Node.erlang_node_name/1`, which builds
  # "#{id}@#{host}". Register "a" for a peer actually called shanghai_a@... and
  # the down event silently matches nothing, so no failover ever happens.
  defp join(node, id) do
    member = Cluster.Entities.Node.new(NodeId.new(id), "127.0.0.1", 4000)
    :erpc.call(node, Cluster.Membership, :join_node, [member])
  end

  # `this_node` is passed explicitly: the coordinator otherwise derives its id
  # from the full Erlang node name, while membership here uses short ids.
  defp start_coordinator(node, group, this_id, member_ids) do
    opts = [
      group_id: group,
      this_node: NodeId.new(this_id),
      members: Enum.map(member_ids, &NodeId.new/1),
      refresh_interval_ms: 200
    ]

    name = {:via, Registry, {Replication.Registry, {:coordinator, group}}}
    {:ok, _} = :erpc.call(node, GenServer, :start, [GroupCoordinator, opts, [name: name]])
  end

  defp role(node, group) do
    :erpc.call(node, GroupCoordinator, :current_role, [group])
  end

  defp await_role(node, group, expected, tries \\ 100) do
    actual = role(node, group)

    cond do
      actual == expected -> actual
      tries == 0 -> actual
      true -> Process.sleep(100) && await_role(node, group, expected, tries - 1)
    end
  end

  describe "leader failover across nodes" do
    test "a surviving majority promotes a new leader when the leader's node dies" do
      group = "failover-#{:rand.uniform(10_000)}"

      # Three members, because promotion now needs a quorum: killing one of
      # three leaves a majority, and the survivors can elect. Peer names double
      # as member ids - see join/2.
      ids = [id_a, id_b, id_c] = ["shanghai_a", "shanghai_b", "shanghai_c"]
      {peer_a, node_a} = start_peer(:shanghai_a)
      {peer_b, node_b} = start_peer(:shanghai_b)
      {peer_c, node_c} = start_peer(:shanghai_c)

      on_exit(fn ->
        for peer <- [peer_a, peer_b, peer_c] do
          try do
            :peer.stop(peer)
          catch
            _, _ -> :ok
          end
        end
      end)

      start_membership(node_a, id_a)
      start_membership(node_b, id_b)
      start_membership(node_c, id_c)

      # Peers only auto-connect to the test node, so wire them to each other -
      # the job Cluster.Discovery does from seed nodes in a real deployment.
      # Without these links there is no :nodedown to react to, and no vote can
      # be collected either.
      true = :erpc.call(node_b, Node, :connect, [node_a])
      true = :erpc.call(node_c, Node, :connect, [node_a])
      true = :erpc.call(node_c, Node, :connect, [node_b])

      # Every node must see every member before any of them can elect.
      for node <- [node_a, node_b, node_c], id <- ids, do: join(node, id)

      for {node, id} <- [{node_a, id_a}, {node_b, id_b}, {node_c, id_c}] do
        start_coordinator(node, group, id, ids)
      end

      # Smallest member id wins the deterministic election.
      assert await_role(node_a, group, :leader) == :leader
      assert await_role(node_b, group, :follower) == :follower
      assert await_role(node_c, group, :follower) == :follower

      # Kill the leader's entire node, not just its processes: the promotion
      # has to come from :nodedown reaching the survivors' membership, and the
      # new leader has to win a real vote from the remaining majority.
      :peer.stop(peer_a)

      assert await_role(node_b, group, :leader) == :leader,
             "the surviving majority did not elect a new leader"

      assert await_role(node_c, group, :follower) == :follower
    end

    test "a minority that loses quorum refuses to promote" do
      # The safety half of the same mechanism: with two of three members gone,
      # the survivor is a minority and must NOT make itself writable, however
      # much its local membership view says it is the smallest node up.
      group = "minority-#{:rand.uniform(10_000)}"

      ids = [id_a, id_b, id_c] = ["shanghai_a", "shanghai_b", "shanghai_c"]
      {peer_a, node_a} = start_peer(:shanghai_a)
      {peer_b, node_b} = start_peer(:shanghai_b)
      {peer_c, node_c} = start_peer(:shanghai_c)

      on_exit(fn ->
        for peer <- [peer_a, peer_b, peer_c] do
          try do
            :peer.stop(peer)
          catch
            _, _ -> :ok
          end
        end
      end)

      start_membership(node_a, id_a)
      start_membership(node_b, id_b)
      start_membership(node_c, id_c)

      true = :erpc.call(node_b, Node, :connect, [node_a])
      true = :erpc.call(node_c, Node, :connect, [node_a])
      true = :erpc.call(node_c, Node, :connect, [node_b])

      for node <- [node_a, node_b, node_c], id <- ids, do: join(node, id)

      for {node, id} <- [{node_a, id_a}, {node_b, id_b}, {node_c, id_c}] do
        start_coordinator(node, group, id, ids)
      end

      assert await_role(node_a, group, :leader) == :leader

      # Both of c's peers die: c is alone and cannot reach a majority of three.
      :peer.stop(peer_a)
      :peer.stop(peer_b)

      assert await_role(node_c, group, :leader, 20) != :leader,
             "an isolated minority must not promote itself to leader"
    end
  end
end
