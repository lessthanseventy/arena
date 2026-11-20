defmodule Babylon.InboxTest do
  use Babylon.DataCase

  import Ecto.Query

  alias Babylon.Inbox
  alias Babylon.Message

  @nobody "%999999"

  test "a message is kept until read, and read once" do
    Inbox.send(@nobody, "#1 landed")
    Inbox.send(@nobody, "#2 sent back")
    assert [%Message{text: "#1 landed"}, %Message{text: "#2 sent back"}] = Inbox.take(@nobody)
    assert Inbox.take(@nobody) == []
  end

  test "an unread message is nudged again once its last nudge is old, four times at most" do
    Inbox.send(@nobody, "#1 landed")
    assert Inbox.renudge() == []

    for nudges <- 2..4 do
      Repo.update_all(Message, set: [nudged_at: ~U[2026-01-01 00:00:00Z]])
      assert Inbox.renudge() == [@nobody]
      assert [%Message{nudges: ^nudges}] = Repo.all(Message)
    end

    Repo.update_all(Message, set: [nudged_at: ~U[2026-01-01 00:00:00Z]])
    assert Inbox.renudge() == []
  end

  test "a read message is not nudged" do
    Inbox.send(@nobody, "#1 landed")
    Inbox.take(@nobody)
    Repo.update_all(from(m in Message), set: [nudged_at: ~U[2026-01-01 00:00:00Z]])
    assert Inbox.renudge() == []
  end
end
