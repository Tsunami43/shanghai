defmodule ShanghaiTest do
  use ExUnit.Case
  doctest Shanghai

  test "greets the world" do
    assert Shanghai.hello() == :world
  end
end
