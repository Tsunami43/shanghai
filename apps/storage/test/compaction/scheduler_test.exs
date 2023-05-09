defmodule Storage.Compaction.SchedulerTest do
  @moduledoc "The scheduler delegates to an injectable compactor module."

  use ExUnit.Case, async: false

  alias Storage.Compaction.Scheduler

  defmodule OkCompactor do
    def compact do
      send(:scheduler_listener, {:compacted, :ok})
      :ok
    end
  end

  defmodule ErrCompactor do
    def compact do
      send(:scheduler_listener, {:compacted, :error})
      {:error, :boom}
    end
  end

  setup do
    Process.register(self(), :scheduler_listener)
    :ok
  end

  test "trigger_compaction/0 invokes the compactor" do
    start_supervised!({Scheduler, compactor: OkCompactor, enabled: false})

    Scheduler.trigger_compaction()
    assert_receive {:compacted, :ok}, 1000
  end

  test "stats/0 reports the configuration, including the compactor" do
    start_supervised!({Scheduler, compactor: OkCompactor, enabled: false, interval: 12_345})

    assert {:ok, stats} = Scheduler.stats()
    assert stats.interval == 12_345
    assert stats.enabled == false
    assert stats.compactor == OkCompactor
  end

  test "scheduled compaction fires on the interval when enabled" do
    start_supervised!({Scheduler, compactor: OkCompactor, enabled: true, interval: 20})

    assert_receive {:compacted, :ok}, 1000
  end

  test "a compactor error does not crash the scheduler" do
    start_supervised!({Scheduler, compactor: ErrCompactor, enabled: false})

    Scheduler.trigger_compaction()
    assert_receive {:compacted, :error}, 1000

    # Still responsive after the compactor returned an error.
    assert {:ok, _stats} = Scheduler.stats()
  end
end
