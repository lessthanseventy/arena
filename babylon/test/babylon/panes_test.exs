defmodule Babylon.PanesTest do
  use ExUnit.Case, async: false

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

  test "text typed in the box is its human's, an empty box or a suggestion drawn grey is not" do
    rule = "\e[2m─────\e[0m\n"
    assert Panes.typed?(rule <> "\e[39m❯ typed by me\n" <> rule)
    refute Panes.typed?(rule <> "\e[39m❯ \n" <> rule)
    refute Panes.typed?(rule <> "\e[39m❯ \e[2mreply with the word ok\e[0m\n" <> rule)
    refute Panes.typed?(rule <> "\e[39m❯ \e[38;5;245mtry fixing the tests\e[39m\n" <> rule)
    refute Panes.typed?("no prompt here")
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

  # a tmux whose pane shows the text in its box for the first `stuck` reads, then an empty box
  defp fake_tmux(dir, stuck) do
    File.write!(Path.join(dir, "tmux"), """
    #!/bin/sh
    echo "$*" >> #{dir}/calls
    case "$1" in
      capture-pane)
        [ "$2" = -ep ] && { cat #{dir}/typing 2>/dev/null || cat #{dir}/clear; exit 0; }
        n=$(grep -c '^capture-pane -p' #{dir}/calls)
        if [ "$n" -le #{stuck} ]; then cat #{dir}/stuck; else cat #{dir}/clear; fi ;;
    esac
    """)

    File.write!(Path.join(dir, "stuck"), "❯ #{@line}\n────\n")
    File.write!(Path.join(dir, "clear"), "❯\n────\n")

    File.chmod!(Path.join(dir, "tmux"), 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)
  end

  defp enters(dir),
    do: dir |> Path.join("calls") |> File.read!() |> String.split("\n") |> Enum.count(&(&1 == "send-keys -t %1 Enter"))

  @tag :tmp_dir
  test "Enter is pressed again while the text stays in the box, and no more once it has left", %{tmp_dir: dir} do
    fake_tmux(dir, 2)
    assert Panes.tell("%1", @line) == :ok
    assert enters(dir) == 3
  end

  @tag :tmp_dir
  test "nothing is typed over what its human is typing", %{tmp_dir: dir} do
    fake_tmux(dir, 0)
    File.write!(Path.join(dir, "typing"), "\e[39m❯ half a thought\n────\n")
    assert Panes.tell("%1", @line) == :typing
    refute File.read!(Path.join(dir, "calls")) =~ "send-keys"
  end

  @tag :tmp_dir
  test "a box that never clears is pressed four times more, then left", %{tmp_dir: dir} do
    fake_tmux(dir, 99)
    assert Panes.tell("%1", @line) == :ok
    assert enters(dir) == 5
  end
end
