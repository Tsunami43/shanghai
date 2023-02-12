defmodule Replication.Quorum do
  @moduledoc """
  Utilities for quorum calculations in distributed replication.

  Provides helper functions for determining quorum sizes,
  checking if acknowledgments satisfy requirements, and
  calculating replication thresholds.
  """

  @doc """
  Calculates the quorum size for a given replica count.

  Quorum is defined as floor(N/2) + 1, ensuring a majority.

  ## Examples

      iex> Replication.Quorum.size(3)
      2

      iex> Replication.Quorum.size(5)
      3

      iex> Replication.Quorum.size(1)
      1
  """
  @spec size(pos_integer()) :: pos_integer()
  def size(replica_count) when replica_count > 0 do
    div(replica_count, 2) + 1
  end

  @doc """
  Checks if the given acknowledgment count satisfies quorum.

  ## Examples

      iex> Replication.Quorum.satisfied?(2, 3)
      true

      iex> Replication.Quorum.satisfied?(1, 3)
      false
  """
  @spec satisfied?(non_neg_integer(), pos_integer()) :: boolean()
  def satisfied?(ack_count, replica_count) do
    ack_count >= size(replica_count)
  end

  @doc """
  Returns the minimum number of replicas needed to maintain availability.

  For quorum writes to succeed, at least quorum replicas must be available.

  ## Examples

      iex> Replication.Quorum.min_available(3)
      2

      iex> Replication.Quorum.min_available(5)
      3
  """
  @spec min_available(pos_integer()) :: pos_integer()
  def min_available(replica_count) do
    size(replica_count)
  end

  @doc """
  Returns the maximum number of failures tolerated while maintaining quorum.

  ## Examples

      iex> Replication.Quorum.max_failures(3)
      1

      iex> Replication.Quorum.max_failures(5)
      2

      iex> Replication.Quorum.max_failures(1)
      0
  """
  @spec max_failures(pos_integer()) :: non_neg_integer()
  def max_failures(replica_count) when replica_count > 0 do
    replica_count - size(replica_count)
  end

  @doc """
  Calculates the percentage of replicas represented by quorum.

  ## Examples

      iex> Replication.Quorum.percentage(3)
      66.67

      iex> Replication.Quorum.percentage(5)
      60.0
  """
  @spec percentage(pos_integer()) :: float()
  def percentage(replica_count) when replica_count > 0 do
    Float.round(size(replica_count) / replica_count * 100, 2)
  end
end
