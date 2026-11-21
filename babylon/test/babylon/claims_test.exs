defmodule Babylon.ClaimsTest do
  use Babylon.DataCase

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

  test "a ticket moved from the backlog to todo can be claimed" do
    {:ok, idea} = Babylon.Tickets.file(%{title: "Idea", status: "backlog"})
    assert idea.status == "backlog"
    {:ok, _} = Babylon.Tickets.update(idea, %{status: "todo"})
    assert {:ok, %{status: "doing"}, :new} = Claims.claim(idea.id, "%1", panes(["%1"]))
  end

  test "refuses a ticket in the backlog, which stays off the board" do
    idea = file!(title: "Someday", status: "backlog")
    assert {:error, "ticket #" <> rest} = Claims.claim(idea.id, "%1", panes(["%1"]))
    assert rest =~ "is in the backlog"
    refute Enum.any?(Babylon.Board.build().tickets, &(&1.id == idea.id))
  end

  test "a session is named after the ticket it claimed last, and how many more it holds" do
    Application.put_env(:babylon, :told_to, self())
    Application.put_env(:babylon, :live_panes, ["%1"])
    on_exit(fn -> for key <- [:told_to, :live_panes], do: Application.delete_env(:babylon, key) end)

    first = file!(title: "Rail shows the ticket")
    second = file!(title: "A session is named after the ticket it claims from babylon")
    {:ok, _, :new} = Claims.claim(first.id, "%1", panes(["%1"]))
    {:ok, _, :new} = Claims.claim(second.id, "%1", panes(["%1"]))
    Repo.update!(Ecto.Changeset.change(Repo.get!(Babylon.Ticket, second.id), claimed_at: ~U[2099-01-01 00:00:00Z]))

    assert Claims.name_session("%1") == :ok
    assert_received {:told, "%1", "/rename #" <> name}
    assert name == "#{second.id} A session is named after the tic +1"
  end

  test "a session waiting at its claim is named on the sweep after, and not again once it is" do
    Application.put_env(:babylon, :told_to, self())
    Application.put_env(:babylon, :live_panes, ["%1"])
    Application.put_env(:babylon, :waiting_panes, ["%1"])

    on_exit(fn ->
      for key <- [:told_to, :live_panes, :waiting_panes, :titles], do: Application.delete_env(:babylon, key)
    end)

    ticket = file!(title: "Lights")
    {:ok, _, :new} = Claims.claim(ticket.id, "%1", panes(["%1"]))
    assert Claims.name_session("%1") == :waiting
    assert Claims.name_sessions() == []
    refute_received {:told, _, _}

    Application.put_env(:babylon, :waiting_panes, [])
    assert Claims.name_sessions() == ["%1"]
    assert_received {:told, "%1", "/rename #" <> _}

    Application.put_env(:babylon, :titles, %{"%1" => "##{ticket.id} Lights"})
    assert Claims.name_sessions() == []
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
    assert Tickets.get(epic.id).status == "todo"
  end
end
