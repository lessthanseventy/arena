defmodule Babylon.Repo.Migrations.Tickets do
  use Ecto.Migration

  def change do
    create table(:ticket) do
      add :repo, :text
      add :title, :text, null: false
      add :body, :text, null: false, default: ""
      add :kind, :text, null: false, default: "ticket", check: %{name: "kind", expr: "kind in ('ticket', 'epic')"}

      add :status, :text,
        null: false,
        default: "backlog",
        check: %{name: "status", expr: "status in ('backlog', 'todo', 'doing', 'done')"}

      add :priority, :text,
        null: false,
        default: "med",
        check: %{name: "priority", expr: "priority in ('low', 'med', 'high')"}

      add :labels, {:array, :text}, null: false, default: "[]"
      add :filed_by, :text
      add :sort, :integer, null: false, default: 0
      add :closed_at, :utc_datetime
      add :claimed_by, :text
      add :claimed_at, :utc_datetime
      add :branch, :text
      timestamps(type: :utc_datetime)
    end

    create index(:ticket, [:repo, :status, :sort])
    create index(:ticket, [:claimed_by], where: "claimed_by IS NOT NULL")

    create table(:ticket_link) do
      add :from_id, references(:ticket, on_delete: :delete_all), null: false

      add :to_id, references(:ticket, on_delete: :delete_all),
        null: false,
        check: %{name: "not_self", expr: "from_id <> to_id"}

      add :kind, :text,
        null: false,
        check: %{name: "kind", expr: "kind in ('blocks', 'relates', 'duplicates', 'parent')"}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # SQLite cannot add a table's constraint after it is made, so this one is a statement of its own
    create unique_index(:ticket_link, [:from_id, :to_id, :kind])
    # one parent a ticket; SQLite names the column, which is this index's default name
    create unique_index(:ticket_link, [:to_id], where: "kind = 'parent'")
  end
end
