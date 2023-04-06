defmodule Storage do
  @moduledoc """
  Public facade for the storage subsystem (the Write-Ahead Log).

  Thin delegation to the WAL processes plus a small runtime summary. The full
  stack (`Writer`/`Reader`) is available when `:storage` is configured with a
  `data_root`; the segment `Registry`/`SegmentManager` are always running.
  """

  alias Storage.WAL.{Reader, SegmentManager, Writer}

  @doc "Appends data to the WAL. Requires the WAL `Writer` to be running."
  @spec append(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate append(data), to: Writer

  @doc "Reads a log entry by LSN. Requires the WAL `Reader` to be running."
  @spec read(non_neg_integer()) :: {:ok, term()} | {:error, term()}
  defdelegate read(lsn), to: Reader

  @doc """
  Returns a runtime summary of the storage subsystem.

  ## Examples

      iex> info = Storage.info()
      iex> is_boolean(info.wal_running) and is_integer(info.active_segments)
      true
  """
  @spec info() :: %{wal_running: boolean(), active_segments: non_neg_integer()}
  def info do
    %{
      wal_running: is_pid(Process.whereis(Writer)),
      active_segments: SegmentManager.count()
    }
  end
end
