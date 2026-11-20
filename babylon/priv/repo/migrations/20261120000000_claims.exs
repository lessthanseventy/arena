defmodule Babylon.Repo.Migrations.Claims do
  use Ecto.Migration

  def change do
    alter table(:ticket) do
      add :claimed_by, :text
      add :claimed_at, :utc_datetime
      add :branch, :text
    end

    create index(:ticket, [:claimed_by], where: "claimed_by IS NOT NULL")
  end
end
