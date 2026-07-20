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
    test "the survivor promotes itself when the leader's node dies" do
      group = "failover-#{:rand.uniform(10_000)}"

      # Peer names double as member ids - see join/2.
      {id_a, id_b} = {"shanghai_a", "shanghai_b"}
      {peer_a, node_a} = start_peer(:shanghai_a)
      {peer_b, node_b} = start_peer(:shanghai_b)

      on_exit(fn ->
        for peer <- [peer_a, peer_b] do
          try do
            :peer.stop(peer)
          catch
            _, _ -> :ok
          end
        end
      end)

      start_membership(node_a, id_a)
      start_membership(node_b, id_b)

      # Peers only auto-connect to the test node, so wire them to each other -
      # the job Cluster.Discovery does from seed nodes in a real deployment.
      # Without this link there is no :nodedown to react to.
      true = :erpc.call(node_b, Node, :connect, [node_a])

      # Both nodes must see both members before either can elect.
      for node <- [node_a, node_b], id <- [id_a, id_b], do: join(node, id)

      start_coordinator(node_a, group, id_a, [id_a, id_b])
      start_coordinator(node_b, group, id_b, [id_a, id_b])

      # Smallest member id wins the deterministic election.
      assert await_role(node_a, group, :leader) == :leader
      assert await_role(node_b, group, :follower) == :follower

      # Kill the leader's entire node, not just its processes: the promotion
      # has to come from :nodedown reaching the survivor's membership.
      :peer.stop(peer_a)

      assert await_role(node_b, group, :leader) == :leader,
             "survivor did not promote after the leader's node died"
    end
  end
end
