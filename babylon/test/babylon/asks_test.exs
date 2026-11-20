defmodule Babylon.AsksTest do
  use Babylon.DataCase

  alias Babylon.Ask
  alias Babylon.Asks

  @nobody "%999999"

  setup do
    {:ok, ticket} = Babylon.Tickets.file(%{title: "Work", repo: "app"})
    %{ticket: ticket}
  end

  test "an ask is open, on the board, until its one answer", %{ticket: ticket} do
    {:ok, ask} = Asks.ask(%{ticket_id: ticket.id, question: "Which?", options: ["this", "that"]}, @nobody)
    assert [%Ask{question: "Which?"}] = Asks.open()
    assert %{ask: %{id: id, question: "Which?", options: ["this", "that"]}} = card(ticket.id)
    assert id == ask.id

    live = MapSet.new([@nobody])
    assert {:error, "ask ##{id} has options 1 to 2"} == Asks.answer(id, 3, live)
    assert {:ok, %Ask{answer: "that"}} = Asks.answer(id, 2, live)
    assert {:error, "ask ##{id} is answered already"} == Asks.answer(id, 1, live)
    assert Asks.open() == []
    assert %{ask: nil} = card(ticket.id)
  end

  test "an ask needs its ticket and two to nine options", %{ticket: ticket} do
    assert {:error, "no ticket #0"} = Asks.ask(%{ticket_id: 0, question: "?", options: ["a", "b"]}, @nobody)
    assert {:error, changeset} = Asks.ask(%{ticket_id: ticket.id, question: "?", options: ["a"]}, @nobody)
    assert %{options: [_]} = errors_on(changeset)
  end

  test "a ticket has one open ask at a time", %{ticket: ticket} do
    {:ok, first} = Asks.ask(%{ticket_id: ticket.id, question: "Which?", options: ["a", "b"]}, @nobody)
    message = "##{ticket.id} has ask ##{first.id} open: wait for its answer"
    assert {:error, ^message} = Asks.ask(%{ticket_id: ticket.id, question: "And?", options: ["c", "d"]}, @nobody)

    {:ok, _} = Asks.answer(first.id, 1, MapSet.new([@nobody]))
    assert {:ok, _} = Asks.ask(%{ticket_id: ticket.id, question: "And?", options: ["c", "d"]}, @nobody)
  end

  test "an ask whose session is gone is closed unanswered, not answered into nothing", %{ticket: ticket} do
    {:ok, ask} = Asks.ask(%{ticket_id: ticket.id, question: "Which?", options: ["a", "b"]}, @nobody)
    message = "the session that asked ##{ask.id} is gone (pane #{@nobody}): closed unanswered"
    assert {:error, ^message} = Asks.answer(ask.id, 1, MapSet.new())
    assert %Ask{answer: nil, answered_at: %DateTime{}} = Repo.get(Ask, ask.id)
    assert %{ask: nil} = card(ticket.id)
  end

  defp card(id), do: Enum.find(Babylon.Board.build().tickets, &(&1.id == id))
end
