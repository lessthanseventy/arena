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
    assert Panes.typed?(rule <> "\e[39m❯ \e[38;5;mstill typed\n" <> rule)
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
    d="#{dir}"
    echo "$*" >> "$d/calls"
    case "$1" in
      list-panes) cat "$d/panes" ;;
      capture-pane)
        [ "$2" = -ep ] && { cat "$d/typing" 2>/dev/null || cat "$d/clear"; exit 0; }
        n=$(grep -c '^capture-pane -p' "$d/calls")
        if [ "$n" -le #{stuck} ]; then cat "$d/stuck"; else cat "$d/clear"; fi ;;
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
  test "a name typed is kept on the pane, and is the rail's title at once", %{tmp_dir: dir} do
    fake_tmux(dir, 0)
    assert Panes.mark_named("%1", "#7 Lights") == :ok
    calls = File.read!(Path.join(dir, "calls"))
    assert calls =~ "set -p -t %1 @babylon_named #7 Lights"
    assert calls =~ "set -p -t %1 @arena_claude_title #7 Lights"
  end

  @tag :tmp_dir
  test "each Claude pane's repo is the directory it is in under projects, a worktree counted", %{tmp_dir: dir} do
    fake_tmux(dir, 0)

    File.write!(Path.join(dir, "panes"), """
    %1 claude /p/tlon
    %2 claude /p/arena/.worktrees/t1-x/babylon
    %3 zsh /p/ficciones
    %4 claude /home/elsewhere
    %5 claude /p
    """)

    assert Panes.claude_repos("/p") == %{"%1" => "tlon", "%2" => "arena"}
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
