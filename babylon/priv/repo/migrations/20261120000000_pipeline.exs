defmodule Babylon.Repo.Migrations.Pipeline do
  use Ecto.Migration

  def change do
    alter table(:ticket) do
      add :stage, :text,
        check: %{name: "stage", expr: "stage in ('queued', 'verifying', 'reviewing', 'landing', 'landed', 'failed')"}

      add :stage_note, :text, null: false, default: ""
      add :submitted_at, :utc_datetime
    end
  end
end
