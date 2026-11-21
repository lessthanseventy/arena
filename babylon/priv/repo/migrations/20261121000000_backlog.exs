defmodule Babylon.Repo.Migrations.Backlog do
  use Ecto.Migration

  # SQLite cannot change a column's check, so the table is made again with the new one; foreign keys
  # are off meanwhile, which SQLite allows only outside a transaction
  @disable_ddl_transaction true

  @columns """
  "id" INTEGER PRIMARY KEY AUTOINCREMENT, "repo" TEXT, "title" TEXT NOT NULL,
  "body" TEXT DEFAULT '' NOT NULL,
  "kind" TEXT DEFAULT 'ticket' NOT NULL CONSTRAINT "kind" CHECK (kind in ('ticket', 'epic')),
  "status" TEXT DEFAULT 'todo' NOT NULL CONSTRAINT "status" CHECK (status in (STATUSES)),
  "priority" TEXT DEFAULT 'med' NOT NULL CONSTRAINT "priority" CHECK (priority in ('low', 'med', 'high')),
  "labels" TEXT DEFAULT '[]' NOT NULL, "filed_by" TEXT, "sort" INTEGER DEFAULT 0 NOT NULL,
  "closed_at" TEXT, "claimed_by" TEXT, "claimed_at" TEXT, "branch" TEXT, "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "stage" TEXT CONSTRAINT "stage" CHECK (stage in ('queued', 'verifying', 'reviewing', 'landing', 'landed', 'failed')),
  "stage_note" TEXT DEFAULT '' NOT NULL, "submitted_at" TEXT
  """

  def up do
    rebuild("'backlog', 'todo', 'doing', 'review', 'done'")
  end

  def down do
    repo().query!("UPDATE ticket SET status = 'todo' WHERE status = 'backlog'")
    rebuild("'todo', 'doing', 'review', 'done'")
  end

  # one connection for all of it, as the pragma holds only on its own; the swap is one transaction,
  # so a failure leaves the table as it was
  defp rebuild(statuses) do
    repo().checkout(fn ->
      repo().query!("PRAGMA foreign_keys = OFF")

      try do
        repo().transaction(fn ->
          for sql <- [
                "CREATE TABLE ticket_new (" <> String.replace(@columns, "STATUSES", statuses) <> ")",
                "INSERT INTO ticket_new SELECT * FROM ticket",
                "DROP TABLE ticket",
                "ALTER TABLE ticket_new RENAME TO ticket",
                ~s|CREATE INDEX "ticket_repo_status_sort_index" ON "ticket" ("repo", "status", "sort")|,
                ~s|CREATE INDEX "ticket_claimed_by_index" ON "ticket" ("claimed_by") WHERE claimed_by IS NOT NULL|
              ],
              do: repo().query!(sql)
        end)
      after
        repo().query!("PRAGMA foreign_keys = ON")
      end
    end)
  end
end
