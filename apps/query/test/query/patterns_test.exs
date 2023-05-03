defmodule Query.PatternsTest do
  @moduledoc """
  Validates that the documented usage patterns (event sourcing, counters, work
  queue) actually work on the real Query API.
  """

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "event sourcing: append-only events replay in order" do
    stream = "events:order-1"

    for type <- [:created, :paid, :shipped] do
      {:ok, seq} = Query.increment("seq:#{stream}")
      key = "#{stream}:#{String.pad_leading(Integer.to_string(seq), 6, "0")}"
      {:ok, :written} = Query.write(key, %{type: type})
    end

    {:ok, events} = Query.scan("#{stream}:")
    types = Enum.map(events, fn {_key, event} -> event.type end)

    assert types == [:created, :paid, :shipped]
  end

  test "distributed counter accumulates" do
    for _ <- 1..5, do: Query.increment("hits")
    assert {:ok, 5} = Query.read("hits")
  end

  test "work queue: enqueue then take drains each job once" do
    for id <- 1..3, do: Query.write("queue:job:#{id}", %{id: id})

    {:ok, jobs} = Query.scan("queue:job:")
    assert length(jobs) == 3

    # Drain the queue by taking (atomic get-and-delete) each job once.
    drained = Enum.map(jobs, fn {key, _value} -> Query.take(key) end)

    assert Enum.all?(drained, &match?({:ok, _}, &1))
    assert {:ok, []} = Query.scan("queue:job:")
  end
end
