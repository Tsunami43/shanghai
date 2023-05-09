defmodule Storage.Compaction.Strategy.SizeTieredTest do
  use ExUnit.Case, async: true

  alias Storage.Compaction.Strategy.SizeTiered

  doctest SizeTiered

  @mb 1024 * 1024

  defp seg(id, size_mb, start_lsn), do: %{id: id, size: size_mb * @mb, start_lsn: start_lsn}

  test "compacts a full tier of same-sized segments" do
    segments = [seg(1, 10, 0), seg(2, 12, 100), seg(3, 8, 200), seg(4, 15, 300)]
    assert SizeTiered.select_segments(segments) == [[1, 2, 3, 4]]
  end

  test "does not compact a tier below the minimum segment count" do
    segments = [seg(1, 10, 0), seg(2, 12, 100), seg(3, 8, 200)]
    assert SizeTiered.select_segments(segments) == []
  end

  test "only tiers that reach the minimum are selected" do
    # Tier 0 (<16MB) has 4 -> selected; tier 1 (16-64MB) has 2 -> not.
    segments = [
      seg(1, 10, 0),
      seg(2, 11, 100),
      seg(3, 12, 200),
      seg(4, 13, 300),
      seg(5, 30, 400),
      seg(6, 40, 500)
    ]

    assert SizeTiered.select_segments(segments) == [[1, 2, 3, 4]]
  end

  test "a tier with more than the minimum is chunked into batches" do
    segments = for i <- 1..8, do: seg(i, 10, i * 100)
    # 8 tier-0 segments -> two batches of 4, ordered by start_lsn.
    assert SizeTiered.select_segments(segments) == [[1, 2, 3, 4], [5, 6, 7, 8]]
  end

  test "a partial trailing batch is dropped" do
    segments = for i <- 1..6, do: seg(i, 10, i * 100)
    # 6 tier-0 segments -> one full batch of 4; the remaining 2 are not compacted.
    assert SizeTiered.select_segments(segments) == [[1, 2, 3, 4]]
  end

  test "min_segments can be overridden" do
    segments = [seg(1, 10, 0), seg(2, 12, 100)]
    assert SizeTiered.select_segments(segments, min_segments: 2) == [[1, 2]]
  end

  test "empty input yields no groups" do
    assert SizeTiered.select_segments([]) == []
  end
end
