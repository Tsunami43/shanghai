defmodule Observability do
  @moduledoc """
  Public facade for the observability subsystem: telemetry, metrics and
  structured logging.
  """

  alias Observability.Logger, as: StructuredLogger
  alias Observability.Metrics

  @doc """
  Returns the list of telemetry event names Shanghai emits.

  ## Examples

      iex> [:shanghai, :query, :operation] in Observability.event_names()
      true
  """
  @spec event_names() :: [[atom()]]
  defdelegate event_names(), to: Metrics

  @doc "Generates a new correlation id for request tracing."
  @spec new_correlation_id() :: String.t()
  defdelegate new_correlation_id(), to: StructuredLogger
end
