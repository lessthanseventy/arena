defmodule Babylon.Repo.Migrations.Tickets do
  use Ecto.Migration

  def change do
    create table(:ticket) do
      add :repo, :text
      add :title, :text, null: false
      add :body, :text, null: false, default: ""
      add :kind, :text, null: false, default: "ticket"
      add :status, :text, null: false, default: "backlog"
      add :priority, :text, null: false, default: "med"
      add :labels, {:array, :text}, null: false, default: []
      add :filed_by, :text
      add :sort, :integer, null: false, default: 0
      add :closed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create constraint(:ticket, :kind, check: "kind in ('ticket', 'epic')")
    create constraint(:ticket, :status, check: "status in ('backlog', 'todo', 'doing', 'done')")
    create constraint(:ticket, :priority, check: "priority in ('low', 'med', 'high')")
    create index(:ticket, [:repo, :status, :sort])

    create table(:ticket_link) do
      add :from_id, references(:ticket, on_delete: :delete_all), null: false
      add :to_id, references(:ticket, on_delete: :delete_all), null: false
      add :kind, :text, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create constraint(:ticket_link, :kind, check: "kind in ('blocks', 'relates', 'duplicates', 'parent')")
    create constraint(:ticket_link, :not_self, check: "from_id <> to_id")
    create unique_index(:ticket_link, [:from_id, :to_id, :kind])
    create unique_index(:ticket_link, [:to_id], where: "kind = 'parent'", name: :ticket_link_one_parent)
  end
end
