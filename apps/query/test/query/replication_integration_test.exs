defmodule Query.ReplicationIntegrationTest do
  @moduledoc """
  End-to-end: a write accepted by a replication leader is delivered to a follower
  whose `:on_apply` callback applies the record to a `Query.Store`, making the
  replicated value readable from that store.
  """

  use ExUnit.Case, async: false

  alias CoreDomain.Types.NodeId
  alias Replication.Stream

  setup do
    ensure_started(fn -> Registry.start_link(keys: :unique, name: Replication.Registry) end)

    ensure_started(fn ->
      DynamicSupervisor.start_link(strategy: :one_for_one, name: Replication.GroupSupervisor)
    end)

    :ok
  end

  test "a leader write is applied to a follower's query store" do
    {:ok, store} = Query.Store.start_link(name: :qri_store, table: :qri_table)

    group = "q-repl-#{:rand.uniform(1_000_000)}"

    {:ok, _leader} =
      Replication.start_leader(group,
        node_id: NodeId.new("leader"),
        replica_count: 1,
        batch_size: 1
      )

    {:ok, _follower} =
      Replication.start_follower(group,
        node_id: NodeId.new("follower"),
        on_apply: {Query.Store, :apply_replicated, [store]}
      )

    Stream.add_follower(group, NodeId.new("follower"))
    Process.sleep(50)

    # Replicate a query put record through the leader.
    {:ok, _offset} =
      Replication.Leader.write(group, %{op: :put, key: "user:1", value: "Alice"},
        consistency_level: :local
      )

    Process.sleep(150)

    # The follower applied the replicated record into the query store.
    assert {:ok, "Alice"} = Query.Store.get(store, "user:1")

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Replication.GroupSupervisor) do
        DynamicSupervisor.terminate_child(Replication.GroupSupervisor, pid)
      end

      if Process.alive?(store), do: GenServer.stop(store)
    end)
  end

  defp ensure_started(start_fun) do
    case start_fun.() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
