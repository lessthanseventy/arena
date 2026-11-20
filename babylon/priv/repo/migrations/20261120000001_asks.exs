defmodule Babylon.Repo.Migrations.Asks do
  use Ecto.Migration

  def change do
    create table(:ask) do
      add :ticket_id, references(:ticket, on_delete: :delete_all), null: false
      add :pane, :text, null: false
      add :question, :text, null: false
      add :options, {:array, :text}, null: false
      add :answer, :text
      add :answered_at, :utc_datetime
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:ask, [:ticket_id], where: "answered_at IS NULL")
  end
end
