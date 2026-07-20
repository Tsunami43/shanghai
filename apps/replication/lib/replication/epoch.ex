defmodule Replication.Epoch do
  @moduledoc """
  Per-node record of the highest leadership epoch seen for each replication
  group, and of the vote this node has cast in it.

  An epoch is a monotonically increasing integer identifying one leadership
  term. It is what makes a stale leader detectable: entries carry the epoch
  they were written under, and a node that has already seen a higher epoch
  rejects them.

  ## Voting rules

  `grant_vote/4` is the only way an epoch advances through a vote, and it
  applies both of Raft's election safety conditions:

  - **One vote per epoch.** A vote is granted only for an epoch strictly
    greater than the highest seen, so a node cannot vote for two candidates in
    the same epoch and two candidates cannot both reach a majority.
  - **The candidate's log must be at least as complete.** A candidate whose
    offset is behind this node's is refused, so a node missing acknowledged
    entries cannot win.

  ## Durability limit

  State is held in memory only. A node that restarts forgets the epoch it has
  seen and the vote it cast, so it may vote a second time in an epoch it had
  already voted in. Closing that hole requires persisting the epoch before
  replying to a vote - not implemented. In exchange, this is safe against the
  failure it targets: a leader that was demoted, or isolated by a partition,
  cannot keep writing once a newer epoch exists.
  """

  use GenServer

  alias CoreDomain.Types.NodeId
  alias Replication.ValueObjects.ReplicationOffset

  @table __MODULE__

  @type vote_result :: :granted | {:denied, :stale_epoch | :behind_log | :already_voted}

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns the highest epoch seen for `group_id`, or `0` when none is known.
  """
  @spec current(String.t()) :: non_neg_integer()
  def current(group_id) do
    case lookup(group_id) do
      nil -> 0
      {epoch, _voted_for} -> epoch
    end
  end

  @doc """
  Returns the node this one voted for in the current epoch, or `nil`.
  """
  @spec voted_for(String.t()) :: NodeId.t() | nil
  def voted_for(group_id) do
    case lookup(group_id) do
      nil -> nil
      {_epoch, voted_for} -> voted_for
    end
  end

  @doc """
  Records that `epoch` exists for `group_id` without casting a vote.

  Used when a higher epoch is observed on the data path (an entry, an ack, a
  losing vote reply). Never lowers the stored epoch. Returns the epoch in
  effect afterwards.
  """
  @spec observe(String.t(), non_neg_integer()) :: non_neg_integer()
  def observe(group_id, epoch) when is_integer(epoch) and epoch >= 0 do
    GenServer.call(__MODULE__, {:observe, group_id, epoch})
  end

  @doc """
  Decides this node's vote for `candidate` standing for `epoch` in `group_id`.

  Granted only when `epoch` is strictly greater than the highest seen and the
  candidate's `candidate_offset` is at least this node's `local_offset`. A
  granted vote advances the stored epoch, so the next candidate in the same
  epoch is refused.
  """
  @spec grant_vote(String.t(), non_neg_integer(), NodeId.t(), keyword()) :: vote_result()
  def grant_vote(group_id, epoch, %NodeId{} = candidate, opts \\ []) do
    GenServer.call(__MODULE__, {:grant_vote, group_id, epoch, candidate, opts})
  end

  @doc """
  Drops all state for `group_id`. Intended for tests and group teardown.
  """
  @spec forget(String.t()) :: :ok
  def forget(group_id) do
    GenServer.call(__MODULE__, {:forget, group_id})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Reads go straight to ETS; writes are serialized through this process so a
    # vote decision and the epoch bump it implies cannot interleave.
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:observe, group_id, epoch}, _from, state) do
    stored = stored_epoch(group_id)

    effective =
      if epoch > stored do
        # A newer epoch invalidates any vote cast in an older one.
        :ets.insert(@table, {group_id, epoch, nil})
        epoch
      else
        stored
      end

    {:reply, effective, state}
  end

  def handle_call({:grant_vote, group_id, epoch, candidate, opts}, _from, state) do
    {:reply, decide_vote(group_id, epoch, candidate, opts), state}
  end

  def handle_call({:forget, group_id}, _from, state) do
    :ets.delete(@table, group_id)
    {:reply, :ok, state}
  end

  # Private

  defp decide_vote(group_id, epoch, candidate, opts) do
    stored = stored_epoch(group_id)

    cond do
      epoch < stored ->
        {:denied, :stale_epoch}

      epoch == stored ->
        # Either this node already voted in this epoch, or it has seen a leader
        # in it. Both mean the epoch is spent.
        {:denied, :already_voted}

      behind?(candidate_offset(opts), local_offset(opts)) ->
        # Refusing here is what keeps a candidate missing acknowledged entries
        # from winning: it cannot collect a majority.
        {:denied, :behind_log}

      true ->
        :ets.insert(@table, {group_id, epoch, candidate})
        :granted
    end
  end

  # `nil` on either side means "offset unknown", in which case the completeness
  # check cannot be applied and is skipped rather than guessed.
  defp behind?(nil, _local), do: false
  defp behind?(_candidate, nil), do: false

  defp behind?(candidate, local) do
    ReplicationOffset.compare(candidate, local) == :lt
  end

  defp candidate_offset(opts), do: Keyword.get(opts, :candidate_offset)
  defp local_offset(opts), do: Keyword.get(opts, :local_offset)

  defp stored_epoch(group_id) do
    case lookup(group_id) do
      nil -> 0
      {epoch, _voted_for} -> epoch
    end
  end

  defp lookup(group_id) do
    case :ets.lookup(@table, group_id) do
      [{^group_id, epoch, voted_for}] -> {epoch, voted_for}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end
end
