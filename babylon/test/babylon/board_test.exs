defmodule Babylon.BoardTest do
  use Babylon.DataCase

  alias Babylon.Board
  alias Babylon.Tickets

  defp file!(attrs) do
    {:ok, ticket} = Tickets.file(Map.new(attrs))
    ticket
  end

  test "a card carries its open blockers and its epic, and a ticket done long ago is off the board" do
    epic = file!(title: "Board", kind: "epic")
    blocker = file!(title: "File", epic_id: epic.id)
    done = file!(title: "Done")
    blocked = file!(title: "Draw", blocked_by: [blocker.id, done.id])
    {:ok, _} = Tickets.update(done, %{status: "done"})

    old = file!(title: "Old")
    {:ok, old} = Tickets.update(old, %{status: "done"})
    Repo.update!(Ecto.Changeset.change(old, closed_at: DateTime.add(old.closed_at, -2, :day)))

    cards = Map.new(Board.build().tickets, &{&1.id, &1})

    assert %{blocked_by: [], epic_id: epic_id} = cards[blocker.id]
    assert epic_id == epic.id
    assert %{blocked_by: [blocker_id], epic_id: nil} = cards[blocked.id]
    assert blocker_id == blocker.id
    assert %{status: "done"} = cards[done.id]
    refute Map.has_key?(cards, old.id)
  end

  @tag :tmp_dir
  test "the board is written as JSON, and again when a ticket changes", %{tmp_dir: dir} do
    path = Path.join(dir, "board/board.json")
    ticket = file!(title: "Seen")

    pid = start_supervised!({Board, path})
    :sys.get_state(pid)
    assert %{"tickets" => [%{"title" => "Seen", "status" => "todo"}]} = JSON.decode!(File.read!(path))

    {:ok, _} = Tickets.update(ticket, %{status: "doing"})
    send(pid, :write)
    :sys.get_state(pid)
    assert %{"tickets" => [%{"status" => "doing"}]} = JSON.decode!(File.read!(path))
  end
end
