defmodule Babylon.ClaimsTest do
  use Babylon.DataCase, async: true

  alias Babylon.Claims
  alias Babylon.Tickets

  defp file!(attrs) do
    {:ok, ticket} = Tickets.file(Map.new(attrs))
    ticket
  end

  defp panes(ids), do: MapSet.new(ids)

  test "a claim takes the ticket to doing with a branch named from it" do
    ticket = file!(title: "Rail shows the ticket: a Claude is on!")

    assert {:ok, claimed, :new} = Claims.claim(ticket.id, "%1", panes(["%1"]))
    assert %{status: "doing", claimed_by: "%1", claimed_at: %DateTime{}} = claimed
    assert claimed.branch == "t#{ticket.id}-rail-shows-the-ticket-a-claude-is-on"

    assert {:ok, ^claimed, :held} = Claims.claim(ticket.id, "%1", panes(["%1"]))
  end

  test "refused while a live pane holds it, or anyone does when tmux cannot be asked" do
    ticket = file!(title: "t")
    {:ok, _, :new} = Claims.claim(ticket.id, "%1", panes(["%1", "%2"]))

    assert {:error, "ticket #" <> _ = reason} = Claims.claim(ticket.id, "%2", panes(["%1", "%2"]))
    assert reason =~ "claimed by pane %1"
    assert {:error, _} = Claims.claim(ticket.id, "%2", :unknown)

    assert {:ok, %{claimed_by: "%2"}, :resumed} = Claims.claim(ticket.id, "%2", panes(["%2"]))
  end

  test "refuses an epic, a done ticket, an open blocker and no ticket at all" do
    epic = file!(title: "e", kind: "epic")
    blocker = file!(title: "blocker")
    blocked = file!(title: "blocked", blocked_by: [blocker.id])
    {:ok, done} = Tickets.update(file!(title: "d"), %{status: "done"})

    assert {:error, "#" <> _} = Claims.claim(epic.id, "%1", panes([]))
    assert {:error, "ticket #" <> _ = reason} = Claims.claim(done.id, "%1", panes([]))
    assert reason =~ "is done"
    assert {:error, reason} = Claims.claim(blocked.id, "%1", panes([]))
    assert reason == "ticket ##{blocked.id} waits on ##{blocker.id}"
    assert {:error, "no ticket #0"} = Claims.claim(0, "%1", panes([]))
  end

  test "release gives it back to todo with its branch; only its pane can" do
    ticket = file!(title: "t")
    {:ok, claimed, :new} = Claims.claim(ticket.id, "%1", panes(["%1"]))

    assert {:error, reason} = Claims.release(ticket.id, "%2")
    assert reason =~ "claimed by pane %1, not this one"

    assert {:ok, %{status: "todo", claimed_by: nil, branch: branch}} = Claims.release(ticket.id, "%1")
    assert branch == claimed.branch
    assert {:error, "ticket #" <> _} = Claims.release(ticket.id, "%1")
  end

  test "a claim whose pane is gone lapses, and nothing lapses when tmux cannot be asked" do
    alive = file!(title: "alive")
    gone = file!(title: "gone")
    {:ok, _, _} = Claims.claim(alive.id, "%1", panes(["%1"]))
    {:ok, _, _} = Claims.claim(gone.id, "%2", panes(["%2"]))

    assert [] == Claims.lapse(:unknown)
    assert [gone.id] == Claims.lapse(panes(["%1"]))

    assert %{status: "todo", claimed_by: nil, labels: ["lapsed"]} = Tickets.get(gone.id)
    assert %{status: "doing", claimed_by: "%1"} = Tickets.get(alive.id)

    assert {:ok, %{labels: []}, :resumed} = Claims.claim(gone.id, "%3", panes(["%1", "%3"]))
  end

  test "an epic's status follows a claim and its release" do
    epic = file!(title: "e", kind: "epic")
    ticket = file!(title: "t", epic_id: epic.id)

    {:ok, _, _} = Claims.claim(ticket.id, "%1", panes(["%1"]))
    assert Tickets.get(epic.id).status == "doing"

    {:ok, _} = Claims.release(ticket.id, "%1")
    assert Tickets.get(epic.id).status == "backlog"
  end
end
