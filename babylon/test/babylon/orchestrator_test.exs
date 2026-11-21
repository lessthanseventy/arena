defmodule Babylon.OrchestratorTest do
  use Babylon.DataCase

  test "with no orchestrator running, telling it keeps nothing" do
    Application.put_env(:babylon, :orchestrator_session, "babylon-test-none")
    on_exit(fn -> Application.delete_env(:babylon, :orchestrator_session) end)
    assert Babylon.Orchestrator.tell("#1 landed") == :ok
    assert Repo.all(Babylon.Message) == []
  end

  test "what the human is shown, a landing, a send-back or an ask, the orchestrator is told" do
    Application.put_env(:babylon, :claude_in, %{"orchestrator" => "%9"})
    Application.put_env(:babylon, :live_panes, ["%9"])
    Application.put_env(:babylon, :told_to, self())
    on_exit(fn -> for k <- [:claude_in, :live_panes, :told_to], do: Application.delete_env(:babylon, k) end)

    {:ok, ticket} = Babylon.Tickets.file(%{title: "Asked"})
    {:ok, _} = Babylon.Asks.ask(%{ticket_id: ticket.id, question: "Which?", options: ["a", "b"]}, "%1")

    assert_received {:told, "%9", "babylon: #" <> asked}
    assert asked =~ "asks: Which?"
  end
end
