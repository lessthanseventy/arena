defmodule Babylon.OrchestratorTest do
  use Babylon.DataCase

  test "with no orchestrator running, telling it keeps nothing" do
    Application.put_env(:babylon, :orchestrator_session, "babylon-test-none")
    on_exit(fn -> Application.delete_env(:babylon, :orchestrator_session) end)
    assert Babylon.Orchestrator.tell("#1 landed") == :ok
    assert Repo.all(Babylon.Message) == []
  end
end
