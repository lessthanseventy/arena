defmodule Babylon.Repo.Migrations.Messages do
  use Ecto.Migration

  def change do
    create table(:message) do
      add :pane, :text, null: false
      add :text, :text, null: false
      add :read_at, :utc_datetime
      add :nudged_at, :utc_datetime
      add :nudges, :integer, null: false, default: 0
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:message, [:pane], where: "read_at IS NULL")
  end
end
