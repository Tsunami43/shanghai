defmodule Query.ModelTest do
  @moduledoc """
  Model-based test: a deterministic pseudo-random sequence of operations is
  applied to both the store and a reference map, asserting they agree at every
  step and at the end. Seeded, so failures are reproducible.
  """

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "store stays consistent with a reference map over a random op sequence" do
    :rand.seed(:exsss, {7, 11, 13})

    model =
      Enum.reduce(1..300, %{}, fn _i, model ->
        key = "k#{:rand.uniform(6)}"
        step(:rand.uniform(6), key, model)
      end)

    # Final agreement between store and model.
    assert Query.count() == map_size(model)
    assert Enum.sort(Query.keys()) == Enum.sort(Map.keys(model))

    Enum.each(model, fn {k, v} -> assert Query.read(k) == {:ok, v} end)
  end

  # 1: write a number
  defp step(1, key, model) do
    value = :rand.uniform(100)
    assert {:ok, :written} = Query.write(key, value)
    Map.put(model, key, value)
  end

  # 2: write a non-numeric value
  defp step(2, key, model) do
    assert {:ok, :written} = Query.write(key, "str")
    Map.put(model, key, "str")
  end

  # 3: delete
  defp step(3, key, model) do
    assert {:ok, :deleted} = Query.delete(key)
    Map.delete(model, key)
  end

  # 4: increment
  defp step(4, key, model) do
    amount = :rand.uniform(10) - 5
    current = Map.get(model, key)

    if current == nil or is_number(current) do
      new = (current || 0) + amount
      assert Query.increment(key, amount) == {:ok, new}
      Map.put(model, key, new)
    else
      assert Query.increment(key, amount) == {:error, :not_a_number}
      model
    end
  end

  # 5: compare-and-swap on absence
  defp step(5, key, model) do
    new = :rand.uniform(100)

    if Map.has_key?(model, key) do
      assert Query.cas(key, :absent, new) == {:error, :precondition_failed}
      model
    else
      assert Query.cas(key, :absent, new) == {:ok, :swapped}
      Map.put(model, key, new)
    end
  end

  # 6: compare-and-swap on the expected current value
  defp step(6, key, model) do
    expected = Map.get(model, key)
    new = :rand.uniform(100)

    if Map.has_key?(model, key) do
      assert Query.cas(key, expected, new) == {:ok, :swapped}
      Map.put(model, key, new)
    else
      # Key is absent, so `expected` is nil and cannot match.
      assert Query.cas(key, expected, new) == {:error, :precondition_failed}
      model
    end
  end
end
