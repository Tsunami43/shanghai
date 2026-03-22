defmodule Cluster.Discovery do
  @moduledoc """
  Connects the node to its configured seed peers over Erlang distribution.

  On start-up and then periodically, the process attempts `Node.connect/1` to
  each configured seed node that is not already connected. Establishing the
  distribution links is what drives the `:nodeup`/`:nodedown` signals that
  `Cluster.Membership` reacts to, so this is the entry point for a node joining a
  real, multi-host cluster.

  Seeds come from `config :cluster, :seed_nodes` (a list of node names as atoms
  or strings). When the node is not running in distributed mode
  (`Node.self() == :nonode@nohost`), connecting is a no-op, so a single-node or
  test deployment needs no configuration.
  """

  use GenServer

  require Logger

  @default_interval_ms 10_000
  @initial_delay_ms 500

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the configured seed node atoms."
  @spec seeds() :: [node()]
  def seeds, do: GenServer.call(__MODULE__, :seeds)

  @doc """
  Attempts to connect to any not-yet-connected seeds now, returning a list of
  `{node, :ok | :error}`. Empty when the node is not distributed.
  """
  @spec connect_now() :: [{node(), :ok | :error}]
  def connect_now, do: GenServer.call(__MODULE__, :connect_now)

  # Server callbacks

  @impl true
  def init(opts) do
    seeds =
      opts
      |> Keyword.get(:seed_nodes, Application.get_env(:cluster, :seed_nodes, []))
      |> parse_seeds()

    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    if seeds != [] do
      Logger.info("Cluster discovery started with #{length(seeds)} seed(s)")
      schedule_connect(@initial_delay_ms)
    end

    {:ok, %{seeds: seeds, interval_ms: interval_ms}}
  end

  @impl true
  def handle_call(:seeds, _from, state), do: {:reply, state.seeds, state}

  def handle_call(:connect_now, _from, state) do
    {:reply, connect_pending(state.seeds), state}
  end

  @impl true
  def handle_info(:connect, state) do
    connect_pending(state.seeds)
    schedule_connect(state.interval_ms)
    {:noreply, state}
  end

  # Pure helpers (unit-tested)

  @doc """
  Normalizes a seed configuration (atoms and/or strings) into a de-duplicated
  list of node atoms, dropping blank entries.
  """
  @spec parse_seeds(term()) :: [node()]
  def parse_seeds(seeds) do
    seeds
    |> List.wrap()
    |> Enum.map(&to_node_atom/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Returns the seeds that still need a connection: everything except the local
  node and the already-connected peers.
  """
  @spec pending_connections([node()], node(), [node()]) :: [node()]
  def pending_connections(seeds, self_node, connected) do
    Enum.reject(seeds, &(&1 == self_node or &1 in connected))
  end

  # Internal

  defp to_node_atom(node) when is_atom(node), do: node

  defp to_node_atom(node) when is_binary(node) do
    case String.trim(node) do
      "" -> nil
      trimmed -> String.to_atom(trimmed)
    end
  end

  defp to_node_atom(_other), do: nil

  # Attempts to connect to the pending seeds. No-op when not distributed.
  defp connect_pending(seeds) do
    if distributed?() do
      seeds
      |> pending_connections(Node.self(), Node.list())
      |> Enum.map(&connect_one/1)
    else
      []
    end
  end

  defp connect_one(node) do
    case Node.connect(node) do
      true ->
        Logger.info("Connected to seed node #{node}")
        {node, :ok}

      _ ->
        Logger.warning("Could not connect to seed node #{node}")
        {node, :error}
    end
  end

  defp distributed?, do: Node.self() != :nonode@nohost

  defp schedule_connect(ms), do: Process.send_after(self(), :connect, ms)
end
