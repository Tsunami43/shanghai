defmodule Storage.Application do
  @moduledoc """
  Application module for the Storage bounded context.

  Starts the Storage.Supervisor which manages all storage-related processes.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Start the Storage.Supervisor which contains all storage processes
    Storage.Supervisor.start_link([])
  end
end
