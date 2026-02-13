defmodule Shanghaictl.Commands.NamespacesTest do
  use ExUnit.Case, async: true

  alias Shanghaictl.Commands.Namespaces

  describe "namespace_lines/1" do
    test "renders the count and per-namespace rows, sorted" do
      body = %{"count" => 2, "namespaces" => %{"us" => 3, "eu" => 2}}

      joined = body |> Namespaces.namespace_lines() |> Enum.join("\n")

      assert joined =~ "Namespaces: 2"
      assert joined =~ "- eu: 2 up"
      assert joined =~ "- us: 3 up"

      rows = Namespaces.namespace_lines(body) |> Enum.drop(1)
      assert rows == ["  - eu: 2 up", "  - us: 3 up"]
    end

    test "handles an empty namespace map" do
      lines = Namespaces.namespace_lines(%{"namespaces" => %{}})
      assert Enum.any?(lines, &(&1 =~ "Namespaces: 0"))
    end
  end
end
