defmodule Babylon.InboxTest do
  use Babylon.DataCase

  alias Babylon.Inbox
  alias Babylon.Message

  @nobody "%999999"

  @live "%1"

  setup do
    Application.put_env(:babylon, :told_to, self())
    Application.put_env(:babylon, :live_panes, [@live])

    on_exit(fn ->
      for key <- [:told_to, :live_panes, :waiting_panes, :working_panes], do: Application.delete_env(:babylon, key)
    end)
  end

  test "a pane between turns is nudged to call inbox, its message kept for it there" do
    Inbox.send(@live, "#1 landed")
    assert_received {:told, @live, "babylon: 1 new message for you: call inbox"}
    assert [%Message{text: "#1 landed"}] = Inbox.take(@live)
  end

  test "nudged once for what came in, not on every sweep; a new one nudges again" do
    Inbox.send(@live, "#1 landed")
    assert_received {:told, @live, _}
    assert Inbox.deliver_held() == []
    refute_received {:told, _, _}

    Inbox.send(@live, "#2 sent back")
    assert_received {:told, @live, "babylon: 2 new messages for you: call inbox"}
  end

  test "held while its pane waits on its human, then nudged once on the sweep after" do
    Application.put_env(:babylon, :waiting_panes, [@live])
    Inbox.send(@live, "#1 landed")
    Inbox.send(@live, "#2 sent back")
    refute_received {:told, _, _}
    assert Inbox.deliver_held() == []

    Application.put_env(:babylon, :waiting_panes, [])
    assert Inbox.deliver_held() == [@live]
    assert_received {:told, @live, "babylon: 2 new messages for you: call inbox"}
    refute_received {:told, _, _}
    assert Inbox.deliver_held() == []
  end

  test "held while its Claude is mid-turn, for arena's hook to hand it over, and taken from there" do
    Application.put_env(:babylon, :working_panes, [@live])
    Inbox.send(@live, "#1 landed")
    assert Inbox.deliver_held() == []
    refute_received {:told, _, _}
    assert [%Message{text: "#1 landed"}] = Inbox.take(@live)
  end

  test "a pane whose human is typing is not nudged, and that is not counted as a try" do
    Application.put_env(:babylon, :typing_panes, [@live])
    on_exit(fn -> Application.delete_env(:babylon, :typing_panes) end)
    Inbox.send(@live, "#1 landed")
    for _ <- 1..5, do: assert(Inbox.deliver_held() == [])
    assert [%Message{nudges: 0}] = Repo.all(Message)

    Application.put_env(:babylon, :typing_panes, [])
    assert Inbox.deliver_held() == [@live]
    assert_received {:told, @live, "babylon: 1 new message for you: call inbox"}
  end

  test "one tmux cannot type is kept to be read, and tried four times in all" do
    Inbox.send(@nobody, "#1 landed")
    for _ <- 2..4, do: assert(Inbox.deliver_held() == [])
    assert [%Message{nudges: 4}] = Repo.all(Message)
    assert Inbox.deliver_held() == []
    assert [%Message{nudges: 4}] = Repo.all(Message)
    assert [%Message{text: "#1 landed"}] = Inbox.take(@nobody)
    assert Inbox.take(@nobody) == []
  end
end
