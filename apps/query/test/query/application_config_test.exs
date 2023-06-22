defmodule Query.ApplicationConfigTest do
  @moduledoc "Read-cache tuning is resolved from application config."

  use ExUnit.Case, async: false

  setup do
    original = Application.get_env(:query, :cache)

    on_exit(fn ->
      if original do
        Application.put_env(:query, :cache, original)
      else
        Application.delete_env(:query, :cache)
      end
    end)

    :ok
  end

  test "keeps only the recognized cache options" do
    Application.put_env(:query, :cache, max_size: 123, ttl_ms: 456, bogus: :ignored)
    assert Query.Application.cache_opts() == [max_size: 123, ttl_ms: 456]
  end

  test "defaults to an empty list when unconfigured" do
    Application.delete_env(:query, :cache)
    assert Query.Application.cache_opts() == []
  end
end
