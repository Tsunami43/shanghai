defmodule Storage.Persistence.FileBackendTest do
  use ExUnit.Case, async: false

  alias Storage.Persistence.FileBackend

  @test_dir Path.join(System.tmp_dir!(), "shanghai_filebackend_test_#{:rand.uniform(999_999)}")

  setup do
    # Clean up test directory before each test
    File.rm_rf(@test_dir)
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf(@test_dir)
    end)

    {:ok, test_dir: @test_dir}
  end

  describe "write_atomic/2 and read_file/1" do
    test "writes and reads file atomically", %{test_dir: dir} do
      path = Path.join(dir, "test.dat")
      data = "test data"

      assert :ok = FileBackend.write_atomic(path, data)
      assert {:ok, ^data} = FileBackend.read_file(path)
    end

    test "overwrites existing file atomically", %{test_dir: dir} do
      path = Path.join(dir, "test.dat")

      assert :ok = FileBackend.write_atomic(path, "first")
      assert {:ok, "first"} = FileBackend.read_file(path)

      assert :ok = FileBackend.write_atomic(path, "second")
      assert {:ok, "second"} = FileBackend.read_file(path)
    end

    test "writes binary data", %{test_dir: dir} do
      path = Path.join(dir, "binary.dat")
      binary = <<0, 1, 2, 255, 254, 253>>

      assert :ok = FileBackend.write_atomic(path, binary)
      assert {:ok, ^binary} = FileBackend.read_file(path)
    end

    test "creates parent directories if needed", %{test_dir: dir} do
      nested_path = Path.join([dir, "nested", "deep", "file.dat"])

      assert :ok = FileBackend.write_atomic(nested_path, "data")
      assert {:ok, "data"} = FileBackend.read_file(nested_path)
    end

    test "returns error for read of nonexistent file" do
      assert {:error, :file_not_found} = FileBackend.read_file("/nonexistent/file.dat")
    end

    test "no temp files left after successful write", %{test_dir: dir} do
      path = Path.join(dir, "test.dat")

      assert :ok = FileBackend.write_atomic(path, "data")

      # Check no .tmp files exist
      {:ok, files} = File.ls(dir)
      assert Enum.all?(files, fn f -> not String.contains?(f, ".tmp") end)
    end
  end

  describe "append_file/2" do
    test "appends data to file", %{test_dir: dir} do
      path = Path.join(dir, "log.txt")

      assert :ok = FileBackend.append_file(path, "line 1\n")
      assert :ok = FileBackend.append_file(path, "line 2\n")
      assert :ok = FileBackend.append_file(path, "line 3\n")

      assert {:ok, "line 1\nline 2\nline 3\n"} = FileBackend.read_file(path)
    end

    test "creates file if it doesn't exist", %{test_dir: dir} do
      path = Path.join(dir, "new.txt")

      assert :ok = FileBackend.append_file(path, "first")
      assert {:ok, "first"} = FileBackend.read_file(path)
    end

    test "creates parent directories", %{test_dir: dir} do
      nested_path = Path.join([dir, "logs", "app.log"])

      assert :ok = FileBackend.append_file(nested_path, "entry")
      assert {:ok, "entry"} = FileBackend.read_file(nested_path)
    end
  end

  describe "ensure_directory/1" do
    test "creates directory", %{test_dir: dir} do
      new_dir = Path.join(dir, "subdir")

      assert :ok = FileBackend.ensure_directory(new_dir)
      assert File.dir?(new_dir)
    end

    test "creates nested directories", %{test_dir: dir} do
      nested = Path.join([dir, "a", "b", "c", "d"])

      assert :ok = FileBackend.ensure_directory(nested)
      assert File.dir?(nested)
    end

    test "succeeds if directory already exists", %{test_dir: dir} do
      assert :ok = FileBackend.ensure_directory(dir)
      assert :ok = FileBackend.ensure_directory(dir)
    end

    test "handles empty string" do
      assert :ok = FileBackend.ensure_directory("")
    end

    test "handles current directory" do
      assert :ok = FileBackend.ensure_directory(".")
    end
  end

  describe "list_files/2" do
    test "lists files matching pattern", %{test_dir: dir} do
      # Create test files
      FileBackend.write_atomic(Path.join(dir, "file1.wal"), "data")
      FileBackend.write_atomic(Path.join(dir, "file2.wal"), "data")
      FileBackend.write_atomic(Path.join(dir, "file3.txt"), "data")

      assert {:ok, files} = FileBackend.list_files(dir, "*.wal")
      assert length(files) == 2
      assert Enum.all?(files, fn f -> String.ends_with?(f, ".wal") end)
    end

    test "returns empty list for no matches", %{test_dir: dir} do
      FileBackend.write_atomic(Path.join(dir, "file.txt"), "data")

      assert {:ok, []} = FileBackend.list_files(dir, "*.wal")
    end

    test "returns sorted list", %{test_dir: dir} do
      FileBackend.write_atomic(Path.join(dir, "c.dat"), "data")
      FileBackend.write_atomic(Path.join(dir, "a.dat"), "data")
      FileBackend.write_atomic(Path.join(dir, "b.dat"), "data")

      assert {:ok, [a, b, c]} = FileBackend.list_files(dir, "*.dat")
      assert String.ends_with?(a, "a.dat")
      assert String.ends_with?(b, "b.dat")
      assert String.ends_with?(c, "c.dat")
    end

    test "returns error for nonexistent directory" do
      assert {:error, :directory_not_found} = FileBackend.list_files("/nonexistent", "*.txt")
    end
  end

  describe "delete_file/1" do
    test "deletes existing file", %{test_dir: dir} do
      path = Path.join(dir, "delete_me.txt")
      FileBackend.write_atomic(path, "data")

      assert File.exists?(path)
      assert :ok = FileBackend.delete_file(path)
      assert not File.exists?(path)
    end

    test "returns error for nonexistent file" do
      assert {:error, :file_not_found} = FileBackend.delete_file("/nonexistent/file.txt")
    end
  end

  describe "file_exists?/1" do
    test "returns true for existing file", %{test_dir: dir} do
      path = Path.join(dir, "exists.txt")
      FileBackend.write_atomic(path, "data")

      assert FileBackend.file_exists?(path)
    end

    test "returns false for nonexistent file" do
      assert not FileBackend.file_exists?("/nonexistent/file.txt")
    end
  end

  describe "file_size/1" do
    test "returns size of file", %{test_dir: dir} do
      path = Path.join(dir, "sized.txt")
      data = "12345678"
      FileBackend.write_atomic(path, data)

      assert {:ok, size} = FileBackend.file_size(path)
      assert size == byte_size(data)
    end

    test "returns 0 for empty file", %{test_dir: dir} do
      path = Path.join(dir, "empty.txt")
      FileBackend.write_atomic(path, "")

      assert {:ok, 0} = FileBackend.file_size(path)
    end

    test "returns error for nonexistent file" do
      assert {:error, :file_not_found} = FileBackend.file_size("/nonexistent.txt")
    end
  end

  describe "sync_file/1" do
    test "syncs open file", %{test_dir: dir} do
      path = Path.join(dir, "sync.txt")
      {:ok, file} = File.open(path, [:write, :binary])

      IO.binwrite(file, "data")
      assert :ok = FileBackend.sync_file(file)

      File.close(file)

      assert {:ok, "data"} = FileBackend.read_file(path)
    end
  end

  describe "atomicity" do
    test "atomic write ensures no partial writes visible", %{test_dir: dir} do
      path = Path.join(dir, "atomic.dat")
      large_data = String.duplicate("x", 1_000_000)

      # Start write in background
      task =
        Task.async(fn ->
          FileBackend.write_atomic(path, large_data)
        end)

      # Give it a moment to start
      Process.sleep(1)

      # If file exists, it should be complete (either old or new)
      if FileBackend.file_exists?(path) do
        {:ok, content} = FileBackend.read_file(path)
        # Should be complete, not partial
        assert byte_size(content) in [0, byte_size(large_data)]
      end

      Task.await(task)
    end
  end

  describe "error handling" do
    test "handles write to readonly directory" do
      # Try to write to root (usually readonly for non-root users)
      result = FileBackend.write_atomic("/readonly_test.dat", "data")

      # Should return an error (either permission denied or directory creation failed)
      assert {:error, _reason} = result
    end
  end
end
