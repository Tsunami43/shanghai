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

  ## Durability

  A vote is only useful if it survives the voter. Before `grant_vote/4`
  replies, the decision is written durably (atomic write, fsync, rename,
  directory fsync) so a node that restarts still remembers it and cannot vote
  twice in the same epoch. If that write fails the vote is **denied** rather
  than granted, because granting a vote this node might forget could elect two
  leaders in one epoch.

  Set the directory with:

      config :replication, epoch_dir: "/var/lib/shanghai/replication/epochs"

  It otherwise defaults to `<storage data_root>/replication/epochs`. With
  neither configured the store runs **in memory only** and logs a warning: a
  restart then forgets votes, and the quorum guarantee holds only as long as
  no member restarts.
  """

  use GenServer
  require Logger

  alias CoreDomain.Types.NodeId
  alias Replication.ValueObjects.ReplicationOffset
  alias Storage.Persistence.FileBackend

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

  @typedoc """
  A node's log position as `{last_entry_epoch, offset}`: the leadership epoch
  the last entry was written under, then the offset. Compared lexicographically,
  this is Raft's "up-to-date" ordering - a higher last epoch wins regardless of
  offset, so a longer but staler log does not beat a shorter, fresher one.
  """
  @type position :: {non_neg_integer(), ReplicationOffset.t()} | nil

  @doc """
  Decides this node's vote for `candidate` standing for `epoch` in `group_id`.

  Granted only when `epoch` is strictly greater than the highest seen and the
  candidate's log is at least as up-to-date as this node's, compared by
  `:candidate_position` against `:local_position` (see `t:position/0`). A
  granted vote advances the stored epoch, so the next candidate in the same
  epoch is refused.
  """
  @spec grant_vote(String.t(), non_neg_integer(), NodeId.t(), keyword()) :: vote_result()
  def grant_vote(group_id, epoch, %NodeId{} = candidate, opts \\ []) do
    GenServer.call(__MODULE__, {:grant_vote, group_id, epoch, candidate, opts})
  end

  @doc """
  Drops all state for `group_id`. Intended for tests and group teardown.

  A no-op when the store is not running: this is cleanup, and there is nothing
  to clean up if it is already gone.
  """
  @spec forget(String.t()) :: :ok
  def forget(group_id) do
    GenServer.call(__MODULE__, {:forget, group_id})
  catch
    :exit, _ -> :ok
  end

  # Server callbacks

  @impl true
  def init(opts) do
    # Reads go straight to ETS; writes are serialized through this process so a
    # vote decision and the epoch bump it implies cannot interleave.
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

    dir = Keyword.get(opts, :data_dir, configured_dir())
    state = %{dir: prepare_dir(dir)}

    load_persisted(state.dir)

    {:ok, state}
  end

  @impl true
  def handle_call({:observe, group_id, epoch}, _from, state) do
    stored = stored_epoch(group_id)

    effective =
      if epoch > stored do
        # A newer epoch invalidates any vote cast in an older one.
        :ets.insert(@table, {group_id, epoch, nil})

        # An observation is not a promise to a peer, so a failed write is
        # logged rather than fatal: this node is still fenced for as long as it
        # stays up.
        case persist(state.dir, group_id, epoch, nil) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "Could not persist epoch #{epoch} for group #{group_id}: #{inspect(reason)}"
            )
        end

        epoch
      else
        stored
      end

    {:reply, effective, state}
  end

  def handle_call({:grant_vote, group_id, epoch, candidate, opts}, _from, state) do
    {:reply, decide_vote(state, group_id, epoch, candidate, opts), state}
  end

  def handle_call({:forget, group_id}, _from, state) do
    :ets.delete(@table, group_id)
    delete_persisted(state.dir, group_id)
    {:reply, :ok, state}
  end

  # Private

  defp decide_vote(state, group_id, epoch, candidate, opts) do
    stored = stored_epoch(group_id)

    cond do
      epoch < stored ->
        {:denied, :stale_epoch}

      epoch == stored ->
        # Either this node already voted in this epoch, or it has seen a leader
        # in it. Both mean the epoch is spent.
        {:denied, :already_voted}

      behind?(candidate_position(opts), local_position(opts)) ->
        # Refusing here is what keeps a candidate missing acknowledged entries
        # from winning: it cannot collect a majority.
        {:denied, :behind_log}

      true ->
        record_vote(state, group_id, epoch, candidate)
    end
  end

  # The vote must be durable BEFORE it is granted. A vote this node could
  # forget across a restart would let it vote twice in one epoch, which is
  # exactly how two leaders get elected in the same term.
  defp record_vote(state, group_id, epoch, candidate) do
    case persist(state.dir, group_id, epoch, candidate) do
      :ok ->
        :ets.insert(@table, {group_id, epoch, candidate})
        :granted

      {:error, reason} ->
        Logger.error(
          "Refusing vote for #{candidate.value} in epoch #{epoch} of group #{group_id}: " <>
            "could not persist the decision (#{inspect(reason)})"
        )

        {:denied, :not_durable}
    end
  end

  # `nil` on either side means the position is unknown, in which case the
  # up-to-date check cannot be applied and is skipped rather than guessed.
  # Otherwise positions compare lexicographically as {epoch, offset}: a higher
  # last epoch is always more up-to-date, and offset only breaks a tie within
  # the same epoch.
  defp behind?(nil, _local), do: false
  defp behind?(_candidate, nil), do: false

  defp behind?({cand_epoch, cand_offset}, {local_epoch, local_offset}) do
    cond do
      cand_epoch < local_epoch -> true
      cand_epoch > local_epoch -> false
      true -> ReplicationOffset.compare(cand_offset, local_offset) == :lt
    end
  end

  defp candidate_position(opts), do: Keyword.get(opts, :candidate_position)
  defp local_position(opts), do: Keyword.get(opts, :local_position)

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

  ## Persistence

  defp configured_dir do
    case Application.get_env(:replication, :epoch_dir) do
      nil -> default_dir()
      dir -> dir
    end
  end

  defp default_dir do
    case Application.get_env(:storage, :data_root) do
      nil -> nil
      root -> Path.join([root, "replication", "epochs"])
    end
  end

  defp prepare_dir(nil) do
    Logger.warning(
      "Replication.Epoch has no directory configured and is running in memory only: " <>
        "a restart forgets votes, so the quorum guarantee holds only while no member restarts. " <>
        "Set config :replication, :epoch_dir to persist them."
    )

    nil
  end

  defp prepare_dir(dir) do
    case FileBackend.ensure_directory(dir) do
      :ok ->
        dir

      {:error, reason} ->
        Logger.error("Cannot use epoch directory #{dir} (#{inspect(reason)}); staying in memory")
        nil
    end
  end

  defp load_persisted(nil), do: :ok

  defp load_persisted(dir) do
    case FileBackend.list_files(dir, "*.epoch") do
      {:ok, paths} ->
        Enum.each(paths, &load_file/1)

      {:error, reason} ->
        Logger.error("Cannot list epoch directory #{dir}: #{inspect(reason)}")
    end
  end

  defp load_file(path) do
    with {:ok, binary} <- FileBackend.read_file(path),
         {:ok, {group_id, epoch, voted_for}} <- decode(binary) do
      :ets.insert(@table, {group_id, epoch, voted_for})
      Logger.info("Recovered epoch #{epoch} for replication group #{group_id}")
    else
      other ->
        # A corrupt record cannot be repaired here, and guessing an epoch would
        # be worse than starting this group from zero.
        Logger.error("Ignoring unreadable epoch file #{path}: #{inspect(other)}")
    end
  end

  defp decode(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      {group_id, epoch, voted_for} when is_binary(group_id) and is_integer(epoch) ->
        {:ok, {group_id, epoch, voted_for}}

      other ->
        {:error, {:unexpected_record, other}}
    end
  rescue
    ArgumentError -> {:error, :corrupt}
  end

  defp persist(nil, _group_id, _epoch, _voted_for), do: :ok

  defp persist(dir, group_id, epoch, voted_for) do
    FileBackend.write_atomic(
      epoch_path(dir, group_id),
      :erlang.term_to_binary({group_id, epoch, voted_for})
    )
  end

  defp delete_persisted(nil, _group_id), do: :ok

  defp delete_persisted(dir, group_id) do
    FileBackend.delete_file(epoch_path(dir, group_id))
  end

  # Group ids are arbitrary strings, so they are encoded rather than used as
  # filenames directly.
  defp epoch_path(dir, group_id) do
    Path.join(dir, Base.url_encode64(group_id, padding: false) <> ".epoch")
  end
end
