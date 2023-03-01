defmodule Observability.Logger do
  @moduledoc """
  Structured logging with correlation ID support.

  This module provides structured logging capabilities with automatic
  correlation ID tracking for request tracing across the distributed system.

  ## Usage

      # Log with automatic correlation ID
      Observability.Logger.info("User logged in", user_id: 123, method: "oauth")

      # Start a new correlation context
      correlation_id = Observability.Logger.new_correlation_id()
      Observability.Logger.with_correlation_id(correlation_id, fn ->
        Observability.Logger.info("Processing request")
        # ... do work ...
      end)

      # Manual correlation ID
      Observability.Logger.info("Replication started",
        correlation_id: "repl-abc123",
        group_id: "group-1"
      )

  ## Correlation ID Propagation

  Correlation IDs are automatically propagated through:
  - Process dictionary (for single-process flows)
  - GenServer calls (via metadata)
  - HTTP requests (via X-Correlation-ID header)
  """

  require Logger

  @correlation_id_key :correlation_id

  @doc """
  Generates a new correlation ID.
  """
  def new_correlation_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Gets the current correlation ID from the process dictionary.
  """
  def get_correlation_id do
    Process.get(@correlation_id_key)
  end

  @doc """
  Sets the correlation ID in the process dictionary.
  """
  def put_correlation_id(correlation_id) do
    Process.put(@correlation_id_key, correlation_id)
  end

  @doc """
  Executes a function with a specific correlation ID.
  """
  def with_correlation_id(correlation_id, fun) when is_function(fun, 0) do
    previous = get_correlation_id()
    put_correlation_id(correlation_id)

    try do
      fun.()
    after
      if previous do
        put_correlation_id(previous)
      else
        Process.delete(@correlation_id_key)
      end
    end
  end

  @doc """
  Logs a debug message with structured metadata.
  """
  def debug(message, metadata \\ []) do
    log(:debug, message, metadata)
  end

  @doc """
  Logs an info message with structured metadata.
  """
  def info(message, metadata \\ []) do
    log(:info, message, metadata)
  end

  @doc """
  Logs a warning message with structured metadata.
  """
  def warning(message, metadata \\ []) do
    log(:warning, message, metadata)
  end

  @doc """
  Logs an error message with structured metadata.
  """
  def error(message, metadata \\ []) do
    log(:error, message, metadata)
  end

  ## Private Functions

  defp log(level, message, metadata) do
    enriched_metadata = enrich_metadata(metadata)

    Logger.log(level, message, enriched_metadata)
  end

  defp enrich_metadata(metadata) do
    base_metadata = [
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      node: Node.self(),
      pid: inspect(self())
    ]

    correlation_id = Keyword.get(metadata, :correlation_id) || get_correlation_id()

    metadata_with_correlation =
      if correlation_id do
        Keyword.put(metadata, :correlation_id, correlation_id)
      else
        metadata
      end

    Keyword.merge(base_metadata, metadata_with_correlation)
  end
end
