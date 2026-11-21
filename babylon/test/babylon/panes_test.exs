defmodule Babylon.PanesTest do
  use ExUnit.Case, async: true

  alias Babylon.Panes

  @line "babylon: #33 landed on main as d9a7b5e; arena's checkout is on it"

  test "a line left in the input box, under its prompt, is pending" do
    screen = """
    ❯ babylon: #29 was sent back: the review asked for changes.
      Queued · ctrl+enter to send now
    ──────────────────────────────────── babylon-ticket-triage-trains ─
    ❯ babylon: #33 landed on main as d9a7b5e; arena's checkout is on it, its install
    running. Its worktree can go: wt remove t33-an-orchestrator
    babylon: #32 landed on main as d9a7b5e

    ────────────────────────────────────────────────────────────────────
      ~/p/arena  ✱ Opus 5.5
    """

    assert Panes.pending?(screen, @line)
    assert Panes.pending?(screen, "babylon: #32 landed on main as d9a7b5e")
  end

  test "a line submitted, shown above an empty box, is not" do
    screen = """
    ❯ babylon: #33 landed on main as d9a7b5e; arena's checkout is on it, its install
      Queued · ctrl+enter to send now
    ────────────────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────────────────
    """

    refute Panes.pending?(screen, @line)
    refute Panes.pending?("no prompt here", @line)
  end
end
