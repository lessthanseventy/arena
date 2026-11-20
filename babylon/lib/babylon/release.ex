defmodule Babylon.Release do
  @moduledoc "What the release runs before it starts: `bin/babylon eval Babylon.Release.migrate()`."

  @doc "Create the database if it is not there, then run every migration."
  @spec migrate() :: :ok
  def migrate do
    Application.load(:babylon)

    for repo <- Application.fetch_env!(:babylon, :ecto_repos) do
      case repo.__adapter__().storage_up(repo.config()) do
        :ok -> :ok
        {:error, :already_up} -> :ok
      end

      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end
end
