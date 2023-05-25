defmodule Admin.IntegrationTest do
  @moduledoc """
  End-to-end smoke test across the public surface: the Query key/value API, the
  cluster status summary, and the aggregate health check, exercised together
  through the running umbrella (the `admin` app depends on every subsystem).
  """

  use ExUnit.Case, async: false

  alias CoreDomain.Types.NodeId

  setup_all do
    # cluster omits `mod:` under test; Replication.Monitor is disabled there.
    case Cluster.Application.start(:normal, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Replication.Monitor.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "the Query key/value API works end to end" do
    assert {:ok, :written} = Query.write("user:1", %{name: "Alice"})
    assert {:ok, %{name: "Alice"}} = Query.read("user:1")

    assert {:ok, 1} = Query.increment("visits")
    assert {:ok, 3} = Query.increment("visits", 2)

    assert {:ok, :swapped} = Query.cas("lock", :absent, :held)
    assert {:error, :precondition_failed} = Query.cas("lock", :absent, :held)

    assert {:ok, :committed} = Query.transact([{:write, "acct:1", 1}, {:write, "acct:2", 2}])
    assert {:ok, [{"acct:1", 1}, {"acct:2", 2}]} = Query.scan("acct:")
    assert {:ok, %{"acct:1" => 1, "acct:2" => 2}} = Query.mget(["acct:1", "acct:2"])

    assert {:ok, %{store: %{size: size}, cache: _}} = Query.info()
    assert size >= 4
  end

  test "cluster status and aggregate health are available" do
    status = Cluster.status()
    assert %NodeId{} = status.local_node_id
    assert is_integer(status.node_count)

    assert Admin.health().status == :healthy
  end
end
