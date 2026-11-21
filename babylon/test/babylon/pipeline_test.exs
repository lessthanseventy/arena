defmodule Babylon.PipelineTest do
  use Babylon.DataCase

  alias Babylon.Pipeline
  alias Babylon.Pipeline.Run
  alias Babylon.Ticket

  @moduletag :tmp_dir
  @nobody "%999999"
  @approve ["sh", "-c", "cat >/dev/null; echo fine; echo 'VERDICT: approve'"]

  # a conflict's resolver that keeps both sides, as its markers dropped; a review it approves
  @keep_both [
    "sh",
    "-c",
    ~S"""
    case "$(cat)" in
      *"stopped on a conflict"*)
        for f in $(git diff --name-only --diff-filter=U); do
          grep -vE '^(<<<<<<<|=======|>>>>>>>)( |$)' "$f" > "$f.kept"; mv "$f.kept" "$f"
        done
        echo RESOLVED ;;
      *) echo 'VERDICT: approve' ;;
    esac
    """
  ]

  setup %{tmp_dir: tmp} do
    was = Application.fetch_env!(:babylon, :pipeline)
    socket = "babylon-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      System.cmd("tmux", ["-L", socket, "kill-server"], stderr_to_stdout: true)
      Application.put_env(:babylon, :pipeline, was)
    end)

    Application.put_env(:babylon, :pipeline, Keyword.put(was, :tmux, ["-L", socket]))
    origin = Path.join(tmp, "origin.git")
    repo = Path.join(tmp, "projects/app")

    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", origin])
    {_, 0} = System.cmd("git", ["clone", "-q", origin, repo], stderr_to_stdout: true)

    sh(
      repo,
      "git checkout -q -b main && echo one > a && echo cache > .gitignore && git add a .gitignore && " <>
        "git commit -qm one && git push -q origin main"
    )

    sh(repo, "git checkout -q -b t1-work && echo two > b && git add b && git commit -qm two && git checkout -q main")

    gated(tmp, ["sh", "-c", "exit 0"], @approve)
    %{origin: origin, repo: repo, ticket: %Ticket{id: 1, repo: "app", branch: "t1-work", title: "Work", body: ""}}
  end

  describe "a run" do
    test "lands the branch on main and says where, stage by stage", %{origin: origin, ticket: ticket} do
      me = self()

      assert {:landed, sha} =
               Run.run(ticket, fn stage ->
                 send(me, {:stage, stage})
                 :ok
               end)

      assert sh(origin, "git rev-parse main") == sha
      for stage <- ~w(verifying reviewing landing), do: assert_received({:stage, ^stage})
    end

    test "a gate still running in the warm worktree, as after a restart, is stopped before it is used",
         %{tmp_dir: tmp, ticket: ticket} do
      [_, socket] = Application.fetch_env!(:babylon, :pipeline)[:tmux]
      pid = Path.join(tmp, "pid")

      {_, 0} =
        System.cmd("tmux", [
          "-L",
          socket,
          "new-session",
          "-d",
          "-s",
          "babylon",
          "-n",
          "app",
          "sh",
          "-c",
          "trap '' HUP; sleep 300 & echo $! > #{pid}; wait"
        ])

      assert eventually(fn -> File.exists?(pid) and File.read!(pid) != "" end)
      left = String.trim(File.read!(pid))

      assert {:landed, _} = Run.run(ticket, fn _ -> :ok end)
      assert {_, 1} = System.cmd("kill", ["-0", left], stderr_to_stdout: true)
    end

    test "runs the gate in a window of the babylon tmux session, kept open to be read", %{ticket: ticket} do
      assert {:landed, _} = Run.run(ticket, fn _ -> :ok end)
      [_, socket] = Application.fetch_env!(:babylon, :pipeline)[:tmux]

      assert {"app\n", 0} =
               System.cmd("tmux", ["-L", socket, "list-windows", "-t", "=babylon", "-F", "\#{window_name}"])
    end

    test "keeps one worktree a repo between runs: its ignored caches stay, the rest is reset",
         %{tmp_dir: tmp, repo: repo, ticket: ticket} do
      assert {:landed, _} = Run.run(ticket, fn _ -> :ok end)
      warm = Path.join(tmp, "work/app")
      File.write!(Path.join(warm, "cache"), "built")
      File.write!(Path.join(warm, "stray"), "left")
      sh(repo, "git checkout -q -b t2-more t1-work && echo four > d && git add d && git commit -qm four")

      assert {:landed, _} = Run.run(%{ticket | id: 2, branch: "t2-more"}, fn _ -> :ok end)
      assert File.read!(Path.join(warm, "cache")) == "built"
      refute File.exists?(Path.join(warm, "stray"))
    end

    test "a conflict with a main that moved is resolved, said in the commit, and gated",
         %{tmp_dir: tmp, repo: repo, origin: origin, ticket: ticket} do
      runs = Path.join(tmp, "runs")
      sh(repo, "git checkout -q -b t6-a main && echo mine >> a && git commit -qam mine && git checkout -q main")
      sh(repo, "echo theirs >> a && git commit -qam theirs && git push -q origin main")
      gated(tmp, ["sh", "-c", "cat a >> #{runs}"], @keep_both)

      assert {:landed, _} = Run.run(%{ticket | id: 6, branch: "t6-a"}, fn _ -> :ok end)
      assert sh(origin, "git show main:a") == "one\ntheirs\nmine"
      assert sh(origin, "git log -1 --format=%B main") =~ "mine\n\nConflict resolved for #6: a"
      assert File.read!(runs) =~ "theirs\nmine"
    end

    test "a resolver that leaves a marker is not trusted: the ticket goes back",
         %{tmp_dir: tmp, repo: repo, origin: origin, ticket: ticket} do
      sh(repo, "git checkout -q -b t6-a main && echo mine >> a && git commit -qam mine && git checkout -q main")
      sh(repo, "echo theirs >> a && git commit -qam theirs && git push -q origin main")
      gated(tmp, ["sh", "-c", "exit 0"], ["sh", "-c", "cat >/dev/null; echo RESOLVED"])

      assert {:failed, "it does not rebase onto main cleanly; conflicts in: a"} =
               Run.run(%{ticket | id: 6, branch: "t6-a"}, fn _ -> :ok end)

      assert sh(origin, "git log --format=%s main") == "theirs\none"
    end

    test "a file deleted on one side and changed on the other is not the resolver's: it goes back",
         %{tmp_dir: tmp, repo: repo, ticket: ticket} do
      sh(repo, "git checkout -q -b t6-a main && echo mine >> a && git commit -qam mine && git checkout -q main")
      sh(repo, "git rm -q a && git commit -qm gone && git push -q origin main")
      gated(tmp, ["sh", "-c", "exit 0"], ["sh", "-c", "cat >/dev/null; echo RESOLVED"])

      assert {:failed, "it does not rebase onto main cleanly; conflicts in: a"} =
               Run.run(%{ticket | id: 6, branch: "t6-a"}, fn _ -> :ok end)
    end

    test "a resolver that touches a file past the conflict is not trusted",
         %{tmp_dir: tmp, repo: repo, ticket: ticket} do
      sh(repo, "git checkout -q -b t6-a main && echo mine >> a && git commit -qam mine && git checkout -q main")
      sh(repo, "echo theirs >> a && git commit -qam theirs && git push -q origin main")
      [sh, c, script] = @keep_both
      gated(tmp, ["sh", "-c", "exit 0"], [sh, c, "echo stray > z; " <> script])

      assert {:failed, "it does not rebase onto main cleanly" <> _} =
               Run.run(%{ticket | id: 6, branch: "t6-a"}, fn _ -> :ok end)
    end

    test "rebases onto a main that moved, keeping both", %{tmp_dir: tmp, origin: origin, ticket: ticket} do
      other = Path.join(tmp, "other")
      sh(tmp, "git clone -q #{origin} #{other}")
      sh(other, "echo three > c && git add c && git commit -qm three && git push -q origin main")

      assert {:landed, _} = Run.run(ticket, fn _ -> :ok end)
      assert sh(origin, "git log --format=%s main") == "two\nthree\none"
    end

    test "a gate that never reached the change says so, as the repo's setup to fix", %{tmp_dir: tmp, ticket: ticket} do
      for line <- [
            "[babylon:check] Unchecked dependencies for environment test:",
            "** (Mix) Could not compile dependency :exqlite",
            "mise ERROR Config files in ~/x/mise.toml are not trusted.",
            "sh: 1: mix: command not found",
            "zsh:1: command not found: zig"
          ] do
        gated(tmp, ["sh", "-c", "echo '#{line}'; exit 1"], @approve)

        assert {:failed, "the gate could not start in babylon's worktree: " <> why} = Run.run(ticket, fn _ -> :ok end)
        assert why =~ "#{line}. That is the repo's setup to fix"
      end
    end

    test "a red change whose output only mentions those lines is red", %{tmp_dir: tmp, ticket: ticket} do
      for line <- [
            ~s(  code: assert out =~ "Unchecked dependencies for environment"),
            "  1) test prints sh: x: command not found back"
          ] do
        gated(tmp, ["sh", "-c", "echo '#{line}'; exit 1"], @approve)
        assert {:failed, "the gate is red (exit 1)" <> _} = Run.run(ticket, fn _ -> :ok end)
      end
    end

    test "stops on a red gate, with its output, and lands nothing", %{tmp_dir: tmp, origin: origin, ticket: ticket} do
      before = sh(origin, "git rev-parse main")
      gated(tmp, ["sh", "-c", "echo boom; exit 3"], @approve)

      assert {:failed, "the gate is red (exit 3); its whole output is in " <> rest} = Run.run(ticket, fn _ -> :ok end)
      [log, "boom"] = String.split(rest, "\n")
      assert log =~ ~r"^#{tmp}/logs/app-t1-\d+\.log$"
      assert File.read!(log) == "boom\n"
      assert sh(origin, "git rev-parse main") == before
    end

    test "a gate that did not run (exit 75) is to be tried again, not the ticket's fault",
         %{tmp_dir: tmp, origin: origin, ticket: ticket} do
      before = sh(origin, "git rev-parse main")
      gated(tmp, ["sh", "-c", "echo 'checks queue: refused'; exit 75"], @approve)

      assert Run.run(ticket, fn _ -> :ok end) == {:retry, "its gate did not run (exit 75): checks queue: refused"}
      assert sh(origin, "git rev-parse main") == before
    end

    test "leads the note of a red gate with its failing lines", %{tmp_dir: tmp, ticket: ticket} do
      gated(tmp, ["sh", "-c", "echo 'FAIL one'; seq 1 50; exit 1"], @approve)

      assert {:failed, note} = Run.run(ticket, fn _ -> :ok end)
      assert [_, "FAIL one", "…", "12" | _] = String.split(note, "\n")
    end

    test "stops when the review asks for changes, with its findings", %{tmp_dir: tmp, ticket: ticket} do
      gated(tmp, ["sh", "-c", "exit 0"], [
        "sh",
        "-c",
        "cat >/dev/null; echo 'b:1 is wrong'; echo 'VERDICT: request_changes'"
      ])

      assert {:failed, "the review asked for changes.\nb:1 is wrong\nVERDICT: request_changes"} =
               Run.run(ticket, fn _ -> :ok end)
    end

    test "lands the review's own small fixes, committed on the branch and gated again",
         %{tmp_dir: tmp, origin: origin, ticket: ticket} do
      fixer = ["sh", "-c", "cat >/dev/null; echo three > b; echo 'FIXED: b:1 two is three'; echo 'VERDICT: fix'"]
      gated(tmp, ["sh", "-c", "echo ran >> ../gates"], fixer)

      assert {:landed, sha, [fixed: "b:1 two is three"]} = Run.run(ticket, fn _ -> :ok end)
      assert sh(origin, "git rev-parse main") == sha
      assert sh(origin, "git show main:b") == "three"
      assert sh(origin, "git log -1 --format=%B main") == "Review fixes for #1\n\n- b:1 two is three"
      assert File.read!(Path.join(tmp, "work/gates")) == "ran\nran\n"
    end

    test "drops what the review edited when it does not say fix", %{tmp_dir: tmp, origin: origin, ticket: ticket} do
      stray = ["sh", "-c", "cat >/dev/null; echo three > b; echo new > c; echo 'VERDICT: approve'"]
      gated(tmp, ["sh", "-c", "exit 0"], stray)

      assert {:landed, _} = Run.run(ticket, fn _ -> :ok end)
      assert sh(origin, "git show main:b") == "two"
      assert sh(origin, "git ls-tree --name-only main") == ".gitignore\na\nb"
    end

    test "lands a change whose findings can follow, each filed as a ticket of its own",
         %{tmp_dir: tmp, origin: origin, ticket: ticket} do
      later = [
        "sh",
        "-c",
        "cat >/dev/null; echo stray > b; echo 'FOLLOWUP: Test the empty case — b:1 has no test for empty'; " <>
          "echo 'VERDICT: approve_with_followups'"
      ]

      gated(tmp, ["sh", "-c", "exit 0"], later)

      assert {:landed, sha, [followup: "Test the empty case — b:1 has no test for empty"]} =
               Run.run(ticket, fn _ -> :ok end)

      assert sh(origin, "git rev-parse main") == sha
      assert sh(origin, "git show main:b") == "two"
      assert Repo.all(Ticket) == []
    end

    test "sends back fixes too big to be one, with the review's findings", %{tmp_dir: tmp, ticket: ticket} do
      big = ["sh", "-c", "cat >/dev/null; seq 100 > b; echo 'FIXED: b rewritten'; echo 'VERDICT: fix'"]
      gated(tmp, ["sh", "-c", "exit 0"], big)

      assert {:failed,
              "the review's fixes ran to 101 lines, more than a fix; its findings:\nFIXED: b rewritten\nVERDICT: fix"} =
               Run.run(ticket, fn _ -> :ok end)
    end

    test "sends back a fix that names no fix, or that changed nothing", %{tmp_dir: tmp, origin: origin, ticket: ticket} do
      unnamed = ["sh", "-c", "cat >/dev/null; echo three > b; echo 'VERDICT: fix'"]
      gated(tmp, ["sh", "-c", "exit 0"], unnamed)

      assert {:failed, "the review said fix but named no FIXED line; its findings:\nVERDICT: fix"} =
               Run.run(ticket, fn _ -> :ok end)

      idle = ["sh", "-c", "cat >/dev/null; echo 'FIXED: b:1 typo'; echo 'VERDICT: fix'"]
      gated(tmp, ["sh", "-c", "exit 0"], idle)

      assert {:failed, "the review said it fixed its findings but changed nothing" <> _} =
               Run.run(ticket, fn _ -> :ok end)

      assert sh(origin, "git ls-tree --name-only main") == ".gitignore\na"
    end

    test "commits only the review's edits, not what the gate left behind", %{
      tmp_dir: tmp,
      origin: origin,
      ticket: ticket
    } do
      fixer = ["sh", "-c", "cat >/dev/null; echo three > b; echo 'FIXED: b:1 typo'; echo 'VERDICT: fix'"]
      gated(tmp, ["sh", "-c", "echo junk > left"], fixer)

      assert {:landed, _, _} = Run.run(ticket, fn _ -> :ok end)
      assert sh(origin, "git ls-tree --name-only main") == ".gitignore\na\nb"
    end

    test "hands the reviewer the diff", %{tmp_dir: tmp, ticket: ticket} do
      seen = Path.join(tmp, "seen")

      gated(tmp, ["sh", "-c", "exit 0"], [
        "sh",
        "-c",
        ~s(cat > #{seen}; echo "$@" >> #{seen}; echo 'VERDICT: approve'),
        "sh"
      ])

      assert {:landed, _} = Run.run(ticket, fn _ -> :ok end)
      assert File.read!(seen) =~ "#1 Work"
      assert File.read!(seen) =~ "--name babylon review · app #1"
      assert File.read!(seen) =~ "+two"
    end

    test "stops on a branch that conflicts with main", %{tmp_dir: tmp, origin: origin, ticket: ticket} do
      other = Path.join(tmp, "other")
      sh(tmp, "git clone -q #{origin} #{other}")
      sh(other, "echo else > b && git add b && git commit -qm else && git push -q origin main")

      assert Run.run(ticket, fn _ -> :ok end) == {:failed, "it does not rebase onto main cleanly; conflicts in: b"}
    end

    test "stops on a branch with nothing to land, or none at all", %{repo: repo, ticket: ticket} do
      sh(repo, "git branch -q t2-empty main")

      assert {:failed, "the branch has nothing main does not"} =
               Run.run(%{ticket | branch: "t2-empty"}, fn _ -> :ok end)

      assert {:failed, "there is no branch t3-none " <> _} = Run.run(%{ticket | branch: "t3-none"}, fn _ -> :ok end)
    end
  end

  describe "submit and finish" do
    setup do
      {:ok, ticket} = Babylon.Tickets.file(%{title: "Work", repo: "app"})
      {:ok, ticket, :new} = Babylon.Claims.claim(ticket.id, @nobody, MapSet.new())
      %{held: ticket}
    end

    test "a release waiting to restart holds the queue, and lets it go when done or over 35 minutes old",
         %{held: held} do
      flag = Path.join(Path.dirname(Application.fetch_env!(:babylon, :pipeline)[:work]), "release-pending")
      on_exit(fn -> File.rm(flag) end)
      {:ok, _} = Pipeline.submit(held.id, @nobody)

      File.touch!(flag)
      assert Pipeline.next_up([]) == nil
      File.rm!(flag)
      assert %Ticket{id: id} = Pipeline.next_up([])
      assert id == held.id

      File.touch!(flag, System.os_time(:second) - 36 * 60)
      assert %Ticket{} = Pipeline.next_up([])
    end

    test "a ticket its pane holds goes to review, queued, and others are refused", %{held: held} do
      assert {:error, "ticket #" <> _} = Pipeline.submit(held.id, "%999998")
      assert {:ok, %Ticket{status: "review", stage: "queued"}} = Pipeline.submit(held.id, @nobody)
      assert {:error, "ticket ##{held.id} is in the pipeline already"} == Pipeline.submit(held.id, @nobody)
    end

    test "landed, it is done, and the human is shown so", %{held: held, tmp_dir: tmp} do
      shown = Path.join(tmp, "shown")
      Application.put_env(:babylon, :notify, ["sh", "-c", ~s(echo "$1" >> #{shown}), "sh"])
      on_exit(fn -> Application.put_env(:babylon, :notify, []) end)

      assert %Ticket{status: "done", stage: "landed", stage_note: "landed on main as abc"} =
               Pipeline.finish(held.id, {:landed, "abc"}, MapSet.new([@nobody]))

      assert File.read!(shown) == "##{held.id} landed on main: Work\n"
    end

    test "a gate to try again keeps the ticket queued, behind a minute, and tells nobody", %{held: held} do
      done = Pipeline.finish(held.id, {:retry, "its gate did not run (exit 75): busy"}, MapSet.new([@nobody]))
      assert %Ticket{stage: "queued", stage_note: "to gate again: " <> _} = done
      assert DateTime.diff(done.submitted_at, DateTime.utc_now()) in 55..60
      assert Pipeline.next_up([]) == nil
      assert Repo.all(Babylon.Message) == []
    end

    test "landed with follow-ups, each is filed then as a ticket of its own, and named", %{held: held} do
      notes = [followup: "Test the empty case — b:1 has no test for empty", followup: " — no title"]
      done = Pipeline.finish(held.id, {:landed, "abc", notes}, MapSet.new([@nobody]), "")

      assert [filed] = Ticket |> Repo.all() |> Enum.filter(&("follow-up" in &1.labels))
      assert %Ticket{repo: "app", title: "Test the empty case", body: "Found by babylon's review of #" <> body} = filed
      assert body =~ "b:1 has no test for empty"

      assert done.stage_note ==
               "landed on main as abc; follow-ups filed: ##{filed.id} Test the empty case; " <>
                 "not filed, as written:  — no title"
    end

    test "landed with the review's fixes, it says which", %{held: held} do
      assert %Ticket{
               status: "done",
               stage_note: "landed on main as abc, with the review's fixes: b:1 typo"
             } =
               Pipeline.finish(held.id, {:landed, "abc", [fixed: "b:1 typo"]}, MapSet.new([@nobody]), "")
    end

    test "next is the first submitted in a repo not already running one" do
      queued = fn title, repo, at ->
        {:ok, t} = Babylon.Tickets.file(%{title: title, repo: repo})
        t |> Ecto.Changeset.change(status: "review", stage: "queued", submitted_at: at) |> Repo.update!()
      end

      first = queued.("First", "tlon", ~U[2026-01-01 00:00:01Z])
      queued.("Second", "tlon", ~U[2026-01-01 00:00:02Z])
      other = queued.("Other", "menard", ~U[2026-01-01 00:00:03Z])

      assert Pipeline.next_up([]).id == first.id
      assert Pipeline.next_up(["tlon"]).id == other.id
      assert Pipeline.next_up(["tlon", "menard"]) == nil
    end

    test "a queued ticket bumped runs before those queued ahead of it", %{held: held} do
      {:ok, other} = Babylon.Tickets.file(%{title: "Other", repo: "app"})

      other
      |> Ecto.Changeset.change(status: "review", stage: "queued", submitted_at: ~U[2026-01-01 00:00:00Z])
      |> Repo.update!()

      assert {:error, "ticket #" <> _} = Pipeline.bump(held.id)

      held
      |> Ecto.Changeset.change(status: "review", stage: "queued", submitted_at: ~U[2026-01-02 00:00:00Z])
      |> Repo.update!()

      assert {:ok, %Ticket{submitted_at: ~U[2025-12-31 23:59:59Z]}} = Pipeline.bump(held.id)
    end

    test "sent back, its session keeps it, or it goes back to the list", %{held: held} do
      assert %Ticket{status: "doing", stage: "failed", stage_note: "red", claimed_by: @nobody} =
               Pipeline.finish(held.id, {:failed, "red"}, MapSet.new([@nobody]))

      assert %Ticket{status: "todo", claimed_by: nil, labels: ["sent back"]} =
               Pipeline.finish(held.id, {:failed, "red"}, MapSet.new())
    end
  end

  describe "a train" do
    setup %{repo: repo, ticket: ticket} do
      sh(
        repo,
        "git checkout -q -b t2-other main && echo four > d && git add d && git commit -qm four && git checkout -q main"
      )

      %{train: [ticket, %{ticket | id: 2, branch: "t2-other", title: "Other"}]}
    end

    test "lands every ticket on one gate, each reviewed apart", %{tmp_dir: tmp, origin: origin, train: train} do
      runs = Path.join(tmp, "runs")
      gated(tmp, ["sh", "-c", "echo run >> #{runs}"], @approve)
      me = self()

      assert [{1, {:landed, sha}}, {2, {:landed, sha}}] =
               train |> Run.train(fn id, stage -> send(me, {id, stage}) end) |> Enum.sort()

      assert sh(origin, "git log --format=%s main") == "four\ntwo\none"
      assert File.read!(runs) == "run\n"
      assert_received {1, "reviewing"}
      assert_received {2, "landing"}
    end

    test "a red train is split: the green half lands, the one at fault goes back",
         %{tmp_dir: tmp, origin: origin, train: train} do
      gated(tmp, ["sh", "-c", "test ! -e d"], @approve)

      assert [{1, {:landed, _}}, {2, {:failed, "the gate is red" <> _}}] =
               train |> Run.train(fn _, _ -> :ok end) |> Enum.sort()

      assert sh(origin, "git log --format=%s main") == "two\none"
    end

    test "a branch built on another in the train lands without its commits twice",
         %{tmp_dir: tmp, repo: repo, origin: origin, ticket: ticket} do
      sh(
        repo,
        "git checkout -q -b t3-on t1-work && echo five > e && git add e && git commit -qm five && git checkout -q main"
      )

      gated(tmp, ["sh", "-c", "exit 0"], @approve)

      assert [{1, {:landed, _}}, {3, {:landed, _}}] =
               [ticket, %{ticket | id: 3, branch: "t3-on"}] |> Run.train(fn _, _ -> :ok end) |> Enum.sort()

      assert sh(origin, "git log --format=%s main") == "five\ntwo\none"
    end

    test "one that will not stack goes back alone", %{tmp_dir: tmp, repo: repo, origin: origin, ticket: ticket} do
      for {branch, text} <- [{"t4-x", "x"}, {"t5-y", "y"}] do
        sh(
          repo,
          "git checkout -q -b #{branch} main && echo #{text} > a && git commit -qam #{text} && git checkout -q main"
        )
      end

      gated(tmp, ["sh", "-c", "exit 0"], @approve)
      cars = [%{ticket | id: 4, branch: "t4-x"}, %{ticket | id: 5, branch: "t5-y"}]

      assert [{4, {:landed, _}}, {5, {:failed, "it does not stack cleanly on main with #4"}}] =
               cars |> Run.train(fn _, _ -> :ok end) |> Enum.sort()

      assert sh(origin, "git log --format=%s main") == "x\none"
    end

    test "one that conflicts with another is stacked once the resolver keeps both",
         %{tmp_dir: tmp, repo: repo, origin: origin, ticket: ticket} do
      for {branch, text} <- [{"t4-x", "x"}, {"t5-y", "y"}] do
        sh(
          repo,
          "git checkout -q -b #{branch} main && echo #{text} > a && git commit -qam #{text} && git checkout -q main"
        )
      end

      gated(tmp, ["sh", "-c", "exit 0"], @keep_both)
      cars = [%{ticket | id: 4, branch: "t4-x"}, %{ticket | id: 5, branch: "t5-y"}]

      assert [{4, {:landed, sha}}, {5, {:landed, sha}}] = cars |> Run.train(fn _, _ -> :ok end) |> Enum.sort()
      assert sh(origin, "git show main:a") == "x\ny"
      assert sh(origin, "git log -1 --format=%B main") =~ "Conflict resolved for #5: a"
    end

    test "a red train of four finds the one at fault in its back half, the rest landing",
         %{tmp_dir: tmp, repo: repo, origin: origin, train: train, ticket: ticket} do
      for {branch, file} <- [{"t6-f", "f"}, {"t7-g", "g"}] do
        sh(
          repo,
          "git checkout -q -b #{branch} main && echo #{file} > #{file} && git add #{file} && git commit -qm #{file} && git checkout -q main"
        )
      end

      gated(tmp, ["sh", "-c", "test ! -e g"], @approve)
      cars = train ++ [%{ticket | id: 6, branch: "t6-f"}, %{ticket | id: 7, branch: "t7-g"}]

      assert [{1, {:landed, _}}, {2, {:landed, _}}, {6, {:landed, _}}, {7, {:failed, "the gate is red" <> _}}] =
               cars |> Run.train(fn _, _ -> :ok end) |> Enum.sort()

      assert sh(origin, "git log --format=%s main") == "f\nfour\ntwo\none"
    end

    test "main moving under a gated train restacks it on main and lands it",
         %{tmp_dir: tmp, origin: origin, train: train} do
      other = Path.join(tmp, "other")
      sh(tmp, "git clone -q #{origin} #{other}")
      moved = Path.join(tmp, "moved")

      once =
        "test -e #{moved} || { touch #{moved}; cd #{other} && echo z > z && git add z && git commit -qm moved && git push -q origin main; }"

      gated(tmp, ["sh", "-c", once], @approve)

      assert [{1, {:landed, _}}, {2, {:landed, _}}] = train |> Run.train(fn _, _ -> :ok end) |> Enum.sort()
      assert sh(origin, "git log --format=%s main") == "four\ntwo\nmoved\none"
    end

    test "one the review refuses drops out, the rest land", %{tmp_dir: tmp, origin: origin, train: train} do
      refuse = ["sh", "-c", "if grep -q Other; then echo 'VERDICT: request_changes'; else echo 'VERDICT: approve'; fi"]
      gated(tmp, ["sh", "-c", "exit 0"], refuse)

      assert [{1, {:landed, _}}, {2, {:failed, "the review asked for changes" <> _}}] =
               train |> Run.train(fn _, _ -> :ok end) |> Enum.sort()

      assert sh(origin, "git log --format=%s main") == "two\none"
    end
  end

  @tag :tmp_dir
  test "gate logs over a week old go, with their exit files; newer ones and install logs stay", %{tmp_dir: tmp} do
    tmp = Path.join(tmp, "logs")
    File.mkdir_p!(tmp)
    old = System.os_time(:second) - 8 * 24 * 3600
    for f <- ~w(app-t1-1.log app-t1-1.log.exit app-install.log), do: File.touch!(Path.join(tmp, f), old)
    File.touch!(Path.join(tmp, "app-t1-2.log"))

    Run.prune_logs(tmp)
    assert tmp |> File.ls!() |> Enum.sort() == ~w(app-install.log app-t1-2.log)
  end

  describe "tidy" do
    setup %{tmp_dir: tmp, repo: repo, ticket: ticket} do
      wt = Path.join(tmp, "wt")
      {_, 0} = System.cmd("git", ["-C", repo, "worktree", "add", "-q", wt, "t1-work"], stderr_to_stdout: true)
      %{wt: wt, landed: Run.run(ticket, fn _ -> :ok end)}
    end

    test "removes a landed branch's worktree and the branch once nobody is in it", %{repo: repo, wt: wt} do
      assert {:kept, "a session is in it"} = Run.tidy("app", "t1-work", [Path.join(wt, "lib")])
      assert File.dir?(wt)

      assert :removed = Run.tidy("app", "t1-work", ["/elsewhere"])
      refute File.exists?(wt)
      assert sh(repo, "git branch --list t1-work") == ""
      assert :absent = Run.tidy("app", "t1-work", [])
    end

    test "keeps one with work not on main, committed or not", %{wt: wt} do
      File.write!(Path.join(wt, "loose"), "x")
      assert {:kept, "it has uncommitted changes"} = Run.tidy("app", "t1-work", [])

      sh(wt, "git add loose && git commit -qm more")
      assert {:kept, "it has commits not on main"} = Run.tidy("app", "t1-work", [])
      assert File.dir?(wt)
    end
  end

  describe "install" do
    test "a checkout on main and clean is fast-forwarded and its install run", %{repo: repo, ticket: ticket} do
      File.write!(Path.join(repo, "mise.toml"), "[tasks.install]\nrun = 'echo installed'\n")
      assert {:landed, sha} = Run.run(ticket, fn _ -> :ok end)
      assert {:ok, log} = Run.install("app")
      assert {^sha <> "\n", 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])

      assert eventually(fn -> File.exists?(log) and File.read!(log) =~ "\ninstalled\n" end)
    end

    test "two opened at once, with no babylon session yet, each get their window",
         %{tmp_dir: tmp, origin: origin} do
      sh(tmp, "git clone -q #{origin} projects/other")
      [socket] = Keyword.fetch!(Application.fetch_env!(:babylon, :pipeline), :tmux) |> Enum.take(-1)

      ["app", "other"]
      |> Enum.map(&Task.async(fn -> Run.install(&1) end))
      |> Enum.each(&assert({:ok, _} = Task.await(&1)))

      {names, 0} = System.cmd("tmux", ["-L", socket, "list-windows", "-t", "=babylon", "-F", "\#{window_name}"])
      assert names |> String.split() |> Enum.sort() == ["app-install", "other-install"]
    end

    test "one off main, or with changes, is left as it is", %{repo: repo, ticket: ticket} do
      assert {:landed, _} = Run.run(ticket, fn _ -> :ok end)
      File.write!(Path.join(repo, "a"), "changed")
      assert {:skipped, "its checkout has changes"} = Run.install("app")
      sh(repo, "git checkout -q -- a && git checkout -q t1-work")
      assert {:skipped, "its checkout is not on main"} = Run.install("app")
    end
  end

  defp eventually(check, tries \\ 50) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually(check, tries - 1)
    end
  end

  defp gated(tmp, gate, reviewer) do
    Application.put_env(
      :babylon,
      :pipeline,
      Keyword.merge(Application.fetch_env!(:babylon, :pipeline),
        projects: Path.join(tmp, "projects"),
        work: Path.join(tmp, "work"),
        gate: gate,
        reviewer: reviewer
      )
    )
  end

  defp sh(dir, script) do
    {out, 0} = System.cmd("sh", ["-c", script], cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end
end
