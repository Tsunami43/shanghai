defmodule ReplicationTest do
  use ExUnit.Case
  doctest Replication

  test "greets the world" do
    assert Replication.hello() == :world
  end
end
