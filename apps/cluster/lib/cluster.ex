defmodule Cluster do
  @moduledoc """
  Public API for Shanghai Cluster functionality.

  This module provides a convenient interface for interacting with the cluster,
  including node membership, discovery, and event subscription.

  ## Architecture

  The cluster is built on three main components:

  - `Cluster.Membership`: Manages cluster topology and node membership
  - `Cluster.Heartbeat`: Monitors node liveness via heartbeat protocol
  - `Cluster.Gossip`: Propagates events and state using gossip protocol

  ## Usage

      # Get all nodes in the cluster
      nodes = Cluster.nodes()

      # Join a new node to the cluster
      node = Cluster.Entities.Node.new(node_id, "localhost", 4000)
      Cluster.join(node)

      # Subscribe to cluster events
      Cluster.subscribe()

      # Leave the cluster
      Cluster.leave(node_id)
  """

  alias Cluster.Entities.Node
  alias Cluster.Membership
  alias CoreDomain.Types.NodeId

  @doc """
  Returns all nodes in the cluster.
  """
  @spec nodes() :: [Node.t()]
  defdelegate nodes(), to: Membership, as: :all_nodes

  @doc """
  Gets a specific node by ID.
  """
  @spec get_node(NodeId.t()) :: {:ok, Node.t()} | {:error, :not_found}
  defdelegate get_node(node_id), to: Membership

  @doc """
  Requests a node to join the cluster.
  """
  @spec join(Node.t()) :: :ok | {:error, atom()}
  defdelegate join(node), to: Membership, as: :join_node

  @doc """
  Requests a node to leave the cluster.
  """
  @spec leave(NodeId.t(), atom()) :: :ok | {:error, atom()}
  defdelegate leave(node_id, reason \\ :graceful), to: Membership, as: :leave_node

  @doc """
  Gets the local node ID.
  """
  @spec local_node_id() :: NodeId.t()
  defdelegate local_node_id(), to: Membership

  @doc """
  Subscribes the calling process to cluster membership events.

  Events are sent as `{:cluster_event, event}` messages.
  """
  @spec subscribe() :: :ok
  defdelegate subscribe(), to: Membership

  @doc """
  Unsubscribes the calling process from cluster membership events.
  """
  @spec unsubscribe() :: :ok
  defdelegate unsubscribe(), to: Membership

  @doc """
  Returns the current cluster state.
  """
  @spec cluster_state() :: Cluster.State.t()
  defdelegate cluster_state(), to: Membership, as: :get_cluster
end
