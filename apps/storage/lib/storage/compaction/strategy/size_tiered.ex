defmodule Storage.Compaction.Strategy.SizeTiered do
  @moduledoc """
  Size-Tiered Compaction Strategy (STCS).

  Groups segments into size tiers and compacts segments within the same tier
  when a sufficient number accumulate.

  ## Strategy

  - Segments are grouped into exponential size buckets:
    - Tier 0: 0-16 MB
    - Tier 1: 16-64 MB
    - Tier 2: 64-256 MB
    - Tier 3: 256+ MB

  - When 4+ segments exist in a tier, they are merged into one larger segment
  - Merged segment moves to next tier
  - This creates exponential growth and limits total segment count

  ## Configuration

  - `:min_segments` - Minimum segments in a tier to trigger compaction (default: 4)
  - `:tier_thresholds` - Size thresholds for tiers in bytes (default: [16MB, 64MB, 256MB])

  ## Examples

      iex> segments = [
      ...>   %{id: 1, size: 10 * 1024 * 1024},  # 10 MB
      ...>   %{id: 2, size: 12 * 1024 * 1024},  # 12 MB
      ...>   %{id: 3, size: 8 * 1024 * 1024},   # 8 MB
      ...>   %{id: 4, size: 15 * 1024 * 1024}   # 15 MB
      ...> ]
      iex> SizeTiered.select_segments(segments)
      [[1, 2, 3, 4]]  # All in tier 0, merge them
  """

  @behaviour Storage.Compaction.Strategy

  # 16 MB, 64 MB, 256 MB
  @default_thresholds [
    16 * 1024 * 1024,
    64 * 1024 * 1024,
    256 * 1024 * 1024
  ]

  @default_min_segments 4

  @doc """
  Selects segments to compact using size-tiered strategy.

  Groups segments by size tier and returns groups with enough segments to compact.

  ## Options

  - `:min_segments` - Minimum segments to trigger compaction (default: 4)
  - `:tier_thresholds` - Size thresholds in bytes (default: [16MB, 64MB, 256MB])

  ## Returns

  List of segment ID groups to compact. Each group contains segment IDs from
  the same tier that should be merged together.
  """
  @impl true
  def select_segments(segments, opts \\ []) do
    min_segments = Keyword.get(opts, :min_segments, @default_min_segments)
    thresholds = Keyword.get(opts, :tier_thresholds, @default_thresholds)

    segments
    |> group_by_tier(thresholds)
    |> select_groups_to_compact(min_segments)
  end

  # Groups segments into size tiers
  @spec group_by_tier([Storage.Compaction.Strategy.segment_info()], [non_neg_integer()]) :: %{
          non_neg_integer() => [Storage.Compaction.Strategy.segment_info()]
        }
  defp group_by_tier(segments, thresholds) do
    Enum.group_by(segments, fn segment ->
      determine_tier(segment.size, thresholds)
    end)
  end

  # Determines which tier a segment belongs to based on size
  @spec determine_tier(non_neg_integer(), [non_neg_integer()]) :: non_neg_integer()
  defp determine_tier(size, thresholds) do
    thresholds
    |> Enum.with_index()
    |> Enum.find(fn {threshold, _index} -> size < threshold end)
    |> case do
      {_threshold, index} -> index
      nil -> length(thresholds)
    end
  end

  # Selects tier groups that have enough segments to compact
  @spec select_groups_to_compact(
          %{non_neg_integer() => [Storage.Compaction.Strategy.segment_info()]},
          non_neg_integer()
        ) :: [[non_neg_integer()]]
  defp select_groups_to_compact(tier_groups, min_segments) do
    tier_groups
    |> Enum.filter(fn {_tier, segments} -> length(segments) >= min_segments end)
    |> Enum.flat_map(fn {_tier, segments} ->
      # Group segments in batches of min_segments
      segments
      |> Enum.sort_by(& &1.start_lsn)
      |> Enum.chunk_every(min_segments)
      |> Enum.filter(&(length(&1) >= min_segments))
      |> Enum.map(fn batch -> Enum.map(batch, & &1.id) end)
    end)
  end
end
