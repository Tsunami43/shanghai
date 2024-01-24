defmodule Observability do
  @moduledoc """
  Public facade for the observability subsystem: telemetry, metrics and
  structured logging.
  """

  alias Observability.Logger, as: StructuredLogger
  alias Observability.Metrics
  alias Observability.MetricsReporter

  @doc """
  Returns the list of telemetry event names Shanghai emits.

  ## Examples

      iex> [:shanghai, :query, :operation] in Observability.event_names()
      true
  """
  @spec event_names() :: [[atom()]]
  defdelegate event_names(), to: Metrics

  @doc "Returns `true` when `event` is one of the emitted telemetry events."
  @spec event_defined?([atom()]) :: boolean()
  defdelegate event_defined?(event), to: Metrics

  @doc "Returns the number of distinct telemetry events Shanghai emits."
  @spec event_count() :: non_neg_integer()
  defdelegate event_count(), to: Metrics

  @doc "Generates a new correlation id for request tracing."
  @spec new_correlation_id() :: String.t()
  defdelegate new_correlation_id(), to: StructuredLogger

  @doc "Returns the current correlation id, or `nil` when none is set."
  @spec correlation_id() :: String.t() | nil
  defdelegate correlation_id(), to: StructuredLogger, as: :get_correlation_id

  @doc """
  Returns the current correlation id, creating and storing one if absent
  (get-or-create).
  """
  @spec ensure_correlation_id() :: String.t()
  defdelegate ensure_correlation_id(), to: StructuredLogger

  @doc """
  Returns a snapshot of the aggregated runtime metrics: WAL, replication,
  heartbeat and query statistics. Each section is `%{}` when its data is not yet
  available.
  """
  @spec stats() :: %{wal: map(), replication: map(), heartbeat: map(), query: map()}
  def stats do
    %{
      wal: safe(fn -> MetricsReporter.get_wal_stats() end),
      replication: safe(fn -> MetricsReporter.get_replication_stats() end),
      heartbeat: safe(fn -> MetricsReporter.get_heartbeat_stats() end),
      query: safe(fn -> MetricsReporter.get_query_stats() end)
    }
  end

  # Runs `fun`, returning `%{}` if the reporter process is unavailable.
  defp safe(fun) do
    fun.()
  catch
    :exit, _ -> %{}
  end
end
