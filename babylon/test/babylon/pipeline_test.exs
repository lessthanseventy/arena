defmodule Babylon.PipelineTest do
  use Babylon.DataCase

  alias Babylon.Pipeline
  alias Babylon.Pipeline.Run
  alias Babylon.Ticket

  @moduletag :tmp_dir
  @nobody "%999999"
  @approve ["sh", "-c", "cat >/dev/null; echo fine; echo 'VERDICT: approve'"]

  setup %{tmp_dir: tmp} do
    was = Application.fetch_env!(:babylon, :pipeline)
    on_exit(fn -> Application.put_env(:babylon, :pipeline, was) end)
    origin = Path.join(tmp, "origin.git")
    repo = Path.join(tmp, "projects/app")

    sh(tmp, "git init -q --bare -b main #{origin} && git clone -q #{origin} #{repo}")
    sh(repo, "git checkout -q -b main && echo one > a && git add a && git commit -qm one && git push -q origin main")
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

    test "rebases onto a main that moved, keeping both", %{tmp_dir: tmp, origin: origin, ticket: ticket} do
      other = Path.join(tmp, "other")
      sh(tmp, "git clone -q #{origin} #{other}")
      sh(other, "echo three > c && git add c && git commit -qm three && git push -q origin main")

      assert {:landed, _} = Run.run(ticket, fn _ -> :ok end)
      assert sh(origin, "git log --format=%s main") == "two\nthree\none"
    end

    test "stops on a red gate, with its output, and lands nothing", %{tmp_dir: tmp, origin: origin, ticket: ticket} do
      before = sh(origin, "git rev-parse main")
      gated(tmp, ["sh", "-c", "echo boom; exit 3"], @approve)

      assert Run.run(ticket, fn _ -> :ok end) == {:failed, "the gate is red (exit 3).\nboom"}
      assert sh(origin, "git rev-parse main") == before
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

    test "hands the reviewer the diff", %{tmp_dir: tmp, ticket: ticket} do
      seen = Path.join(tmp, "seen")
      gated(tmp, ["sh", "-c", "exit 0"], ["sh", "-c", "cat > #{seen}; echo 'VERDICT: approve'"])

      assert {:landed, _} = Run.run(ticket, fn _ -> :ok end)
      assert File.read!(seen) =~ "#1 Work"
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

    test "a ticket its pane holds goes to review, queued, and others are refused", %{held: held} do
      assert {:error, "ticket #" <> _} = Pipeline.submit(held.id, "%999998")
      assert {:ok, %Ticket{status: "review", stage: "queued"}} = Pipeline.submit(held.id, @nobody)
      assert {:error, "ticket ##{held.id} is in the pipeline already"} == Pipeline.submit(held.id, @nobody)
    end

    test "landed, it is done", %{held: held} do
      assert %Ticket{status: "done", stage: "landed", stage_note: "landed on main as abc"} =
               Pipeline.finish(held.id, {:landed, "abc"}, MapSet.new([@nobody]))
    end

    test "sent back, its session keeps it, or it goes back to the list", %{held: held} do
      assert %Ticket{status: "doing", stage: "failed", stage_note: "red", claimed_by: @nobody} =
               Pipeline.finish(held.id, {:failed, "red"}, MapSet.new([@nobody]))

      assert %Ticket{status: "todo", claimed_by: nil, labels: ["sent back"]} =
               Pipeline.finish(held.id, {:failed, "red"}, MapSet.new())
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
