defmodule Babylon.TicketsTest do
  use Babylon.DataCase, async: true

  alias Babylon.Tickets

  defp file!(attrs, opts \\ []) do
    {:ok, ticket} = Tickets.file(Map.new(attrs), opts)
    ticket
  end

  describe "file/2" do
    test "files into the backlog at the bottom of its repo, stamped with the filing session" do
      first = file!(%{repo: "arena", title: "one"}, filed_by: "s-1")
      second = file!(%{repo: "arena", title: "two"})
      elsewhere = file!(%{repo: "tlon", title: "three"})

      assert %{status: "backlog", priority: "med", filed_by: "s-1", labels: []} = first
      assert second.sort == first.sort + 1
      assert elsewhere.sort == 1
    end

    test "refuses a missing title and values outside the closed sets" do
      assert {:error, changeset} = Tickets.file(%{title: nil, status: "someday", priority: "now"})

      assert %{title: ["can't be blank"], status: ["is invalid"], priority: ["is invalid"]} = errors_on(changeset)
    end

    test "under an epic, in one transaction: a refused parent files nothing" do
      epic = file!(%{title: "epic", kind: "epic"})
      plain = file!(%{title: "plain"})

      child = file!(%{title: "child", epic_id: epic.id})
      assert Tickets.epic_of(child.id) == epic.id

      assert {:error, changeset} = Tickets.file(%{title: "orphan", epic_id: plain.id})
      assert %{from_id: ["only an epic can be a parent"]} = errors_on(changeset)
      refute Enum.any?(Tickets.list(), &(&1.title == "orphan"))
    end
  end

  describe "list/1" do
    test "narrows by repo and status, in board order" do
      a = file!(%{repo: "arena", title: "a"})
      b = file!(%{repo: "arena", title: "b"})
      _t = file!(%{repo: "tlon", title: "t"})
      {:ok, _} = Tickets.update(a, %{status: "doing"})

      assert ["a", "b"] == Enum.map(Tickets.list(repo: "arena"), & &1.title)
      assert ["b"] == Enum.map(Tickets.list(repo: "arena", status: "backlog"), & &1.title)
      assert ["a", "b"] == Enum.map(Tickets.list(repo: "arena", status: ~w(backlog doing)), & &1.title)
      assert b.id in Enum.map(Tickets.list(), & &1.id)
    end
  end

  describe "update/2" do
    test "closed_at follows done there and back" do
      ticket = file!(%{title: "t"})

      {:ok, done} = Tickets.update(ticket, %{status: "done"})
      assert done.closed_at

      {:ok, reopened} = Tickets.update(done, %{status: "doing"})
      refute reopened.closed_at
    end

    test "an epic's status follows its tickets' and cannot be set by hand" do
      epic = file!(%{title: "epic", kind: "epic"})
      one = file!(%{title: "one", epic_id: epic.id})
      two = file!(%{title: "two", epic_id: epic.id})

      {:ok, _} = Tickets.update(epic, %{status: "done"})
      assert Tickets.get(epic.id).status == "backlog"

      {:ok, _} = Tickets.update(one, %{status: "doing"})
      assert Tickets.get(epic.id).status == "doing"

      {:ok, _} = Tickets.update(Tickets.get(one.id), %{status: "done"})
      {:ok, _} = Tickets.update(two, %{status: "done"})
      assert Tickets.get(epic.id).status == "done"

      {:ok, _} = Tickets.remove(Tickets.get(two.id))
      {:ok, _} = Tickets.update(Tickets.get(one.id), %{status: "todo"})
      assert Tickets.get(epic.id).status == "backlog"
    end
  end

  describe "links" do
    test "blocks reads from both ends, and a done blocker no longer blocks" do
      blocker = file!(%{title: "blocker"})
      blocked = file!(%{title: "blocked"})

      {:ok, _} = Tickets.link(blocker.id, blocked.id, "blocks")
      {:ok, _} = Tickets.link(blocker.id, blocked.id, "blocks")

      assert [%{kind: "blocks", direction: :in, ticket_id: blocker.id}] == Tickets.links_of(blocked.id)
      assert [%{kind: "blocks", direction: :out, ticket_id: blocked.id}] == Tickets.links_of(blocker.id)
      assert [blocker.id] == Tickets.blockers(blocked.id)

      {:ok, _} = Tickets.update(blocker, %{status: "done"})
      assert [] == Tickets.blockers(blocked.id)

      :ok = Tickets.unlink(blocker.id, blocked.id, "blocks")
      :ok = Tickets.unlink(blocker.id, blocked.id, "blocks")
      assert [] == Tickets.links_of(blocked.id)
    end

    test "refuses a self-link, an unknown kind, an epic under an epic and a second parent" do
      ticket = file!(%{title: "t"})
      epic = file!(%{title: "e", kind: "epic"})
      other = file!(%{title: "o", kind: "epic"})

      assert {:error, cs} = Tickets.link(ticket.id, ticket.id, "relates")
      assert %{to_id: ["a ticket cannot link to itself"]} = errors_on(cs)

      assert {:error, cs} = Tickets.link(ticket.id, epic.id, "follows")
      assert %{kind: ["is invalid"]} = errors_on(cs)

      assert {:error, cs} = Tickets.link(epic.id, other.id, "parent")
      assert %{to_id: ["an epic cannot hold an epic"]} = errors_on(cs)

      {:ok, _} = Tickets.link(epic.id, ticket.id, "parent")
      assert {:error, cs} = Tickets.link(other.id, ticket.id, "parent")
      assert %{to_id: ["already has a parent"]} = errors_on(cs)
    end
  end
end
