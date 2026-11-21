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
      for key <- [:told_to, :live_panes, :waiting_panes], do: Application.delete_env(:babylon, key)
    end)
  end

  test "a message is typed into its pane whole, and so read" do
    Inbox.send(@live, "#1 landed")
    assert_received {:told, @live, "babylon: #1 landed"}
    assert Inbox.take(@live) == []
  end

  test "held while its pane waits on its human, then typed on the sweep after" do
    Application.put_env(:babylon, :waiting_panes, [@live])
    Inbox.send(@live, "#1 landed")
    Inbox.send(@live, "#2 sent back")
    refute_received {:told, _, _}
    assert Inbox.deliver_held() == []

    Application.put_env(:babylon, :waiting_panes, [])
    assert Inbox.deliver_held() == [@live]
    assert_received {:told, @live, "babylon: #1 landed"}
    assert_received {:told, @live, "babylon: #2 sent back"}
    assert Inbox.deliver_held() == []
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
