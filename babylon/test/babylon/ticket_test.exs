defmodule Babylon.TicketTest do
  use ExUnit.Case, async: true

  alias Babylon.Ticket

  test "an epic is in the backlog while all its tickets are, and to do once one is not" do
    assert Ticket.epic_status(["backlog", "backlog"]) == "backlog"
    assert Ticket.epic_status(["backlog", "todo"]) == "todo"
    assert Ticket.epic_status(["backlog", "doing"]) == "doing"
    assert Ticket.epic_status(["done", "done"]) == "done"
  end
end
