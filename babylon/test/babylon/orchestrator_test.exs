defmodule Babylon.OrchestratorTest do
  use Babylon.DataCase

  test "with no orchestrator running, telling it keeps nothing" do
    Application.put_env(:babylon, :orchestrator_session, "babylon-test-none")
    on_exit(fn -> Application.delete_env(:babylon, :orchestrator_session) end)
    assert Babylon.Orchestrator.tell("#1 landed") == :ok
    assert Repo.all(Babylon.Message) == []
  end

  describe "what the human is shown, the orchestrator is told" do
    setup do
      Application.put_env(:babylon, :claude_in, %{"orchestrator" => "%9"})
      Application.put_env(:babylon, :live_panes, ["%9"])
      Application.put_env(:babylon, :told_to, self())
      on_exit(fn -> for k <- [:claude_in, :live_panes, :told_to], do: Application.delete_env(:babylon, k) end)
      {:ok, ticket} = Babylon.Tickets.file(%{title: "Lights"})
      %{ticket: Repo.update!(Ecto.Changeset.change(ticket, status: "review", stage: "landing"))}
    end

    defp told, do: Babylon.Message |> Repo.all() |> Enum.filter(&(&1.pane == "%9")) |> Enum.map(& &1.text)

    test "an ask opened", %{ticket: ticket} do
      {:ok, _} = Babylon.Asks.ask(%{ticket_id: ticket.id, question: "Which?", options: ["a", "b"]}, "%1")
      assert ["#" <> asked] = told()
      assert asked =~ "asks: Which?"
    end

    test "a landing", %{ticket: ticket} do
      Babylon.Pipeline.finish(ticket.id, {:landed, "abc"}, MapSet.new(), "nothing to install")
      assert told() == ["##{ticket.id} landed on main: Lights"]
    end

    test "a send-back", %{ticket: ticket} do
      Babylon.Pipeline.finish(ticket.id, {:failed, "the gate is red\nboom"}, MapSet.new())
      assert told() == ["##{ticket.id} sent back: the gate is red"]
    end
  end
end
