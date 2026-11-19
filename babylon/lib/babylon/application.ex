defmodule Babylon.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Babylon.Repo], strategy: :one_for_one, name: Babylon.Supervisor)
  end
end
