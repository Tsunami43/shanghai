defmodule Storage.Compaction.Strategy do
  @moduledoc """
  Behavior for compaction strategies.

  Defines the interface for different compaction strategies that can be
  used to merge and compact WAL segments.

  Strategies determine which segments to compact and in what order.
  """

  @type segment_info :: %{
          id: non_neg_integer(),
          size: non_neg_integer(),
          start_lsn: non_neg_integer(),
          end_lsn: non_neg_integer(),
          entry_count: non_neg_integer()
        }

  @doc """
  Selects segments to compact based on the strategy.

  Returns a list of segment groups to compact. Each group is a list of
  segment IDs that should be merged together.

  ## Parameters

  - `segments` - List of segment information maps

  ## Returns

  - List of segment ID groups to compact: `[[id1, id2, id3], [id4, id5]]`
  - Empty list if no compaction needed
  """
  @callback select_segments([segment_info()]) :: [[non_neg_integer()]]
end
