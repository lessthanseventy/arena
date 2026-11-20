defmodule Babylon.Pipeline.Run do
  @moduledoc """
  One ticket's way to main, in a throwaway worktree of its repo: rebased onto main, its repo's gate
  run, reviewed headlessly, then pushed as main's new head. Main moving meanwhile means another
  rebase and gate before the push, which only a fast-forward passes.
  """
  alias Babylon.Ticket

  @diff_limit 200_000
  @tail_lines 40

  @doc """
  Take `ticket` through, calling `stage` with each stage as it starts. `{:landed, sha}`, or
  `{:failed, why}` at the first step that refuses it.
  """
  @spec run(Ticket.t(), (String.t() -> :ok)) :: Babylon.Pipeline.outcome()
  def run(%Ticket{} = ticket, stage) do
    repo = Path.join(conf(:projects), ticket.repo)
    dir = Path.join(conf(:work), "#{ticket.repo}-t#{ticket.id}")

    try do
      with :ok <- stage.("verifying"),
           :ok <- checkout(repo, dir, ticket.branch),
           :ok <- onto_main(dir),
           :ok <- ahead(dir),
           :ok <- gate(dir),
           :ok <- stage.("reviewing"),
           :ok <- review(dir, ticket),
           :ok <- stage.("landing") do
        land(dir, 3)
      end
    after
      git(repo, ["worktree", "remove", "--force", dir])
    end
  end

  defp checkout(repo, dir, branch) do
    git(repo, ["worktree", "remove", "--force", dir])
    File.rm_rf!(dir)
    git(repo, ["worktree", "prune"])

    cond do
      not File.dir?(repo) ->
        {:failed, "there is no checkout of it at #{repo}"}

      not match?({_, 0}, git(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"])) ->
        {:failed, "there is no branch #{branch} in #{repo}: commit the work on it first"}

      true ->
        File.mkdir_p!(Path.dirname(dir))
        ok(git(repo, ["worktree", "add", "-q", "--detach", dir, branch]), "could not check it out")
    end
  end

  defp onto_main(dir) do
    with :ok <- ok(git(dir, ["fetch", "-q", "origin", "main"]), "could not fetch origin's main") do
      case git(dir, ["rebase", "-q", "origin/main"]) do
        {_, 0} ->
          :ok

        _ ->
          {conflicts, _} = git(dir, ["diff", "--name-only", "--diff-filter=U"])
          git(dir, ["rebase", "--abort"])
          {:failed, "it does not rebase onto main cleanly; conflicts in: " <> Enum.join(String.split(conflicts), ", ")}
      end
    end
  end

  defp ahead(dir) do
    case git(dir, ["rev-list", "--count", "origin/main..HEAD"]) do
      {"0\n", 0} -> {:failed, "the branch has nothing main does not"}
      _ -> :ok
    end
  end

  defp gate(dir) do
    minutes = div(conf(:gate_timeout), 60)

    case cmd(conf(:gate), dir, timeout: conf(:gate_timeout), env: [{"MISE_TRUSTED_CONFIG_PATHS", dir}]) do
      {_, 0} -> :ok
      {_, 124} -> {:failed, "the gate ran past #{minutes} minutes"}
      {out, code} -> {:failed, "the gate is red (exit #{code}).\n" <> tail(out)}
    end
  end

  defp review(dir, ticket) do
    {diff, 0} = git(dir, ["diff", "origin/main...HEAD"])
    prompt = dir <> ".review"
    File.write!(prompt, review_prompt(ticket, String.slice(diff, 0, @diff_limit)))

    try do
      case cmd(conf(:reviewer), dir, timeout: conf(:review_timeout), stdin: prompt) do
        {out, 0} -> verdict(out)
        {_, 124} -> {:failed, "the review ran past #{div(conf(:review_timeout), 60)} minutes"}
        {out, code} -> {:failed, "the reviewer failed (exit #{code}).\n" <> tail(out)}
      end
    after
      File.rm(prompt)
    end
  end

  defp verdict(out) do
    case Regex.scan(~r/^VERDICT: (approve|request_changes)\s*$/m, out) do
      [] ->
        {:failed, "the review gave no verdict.\n" <> tail(out)}

      found ->
        case List.last(found) do
          [_, "approve"] -> :ok
          [_, "request_changes"] -> {:failed, "the review asked for changes.\n" <> String.trim(out)}
        end
    end
  end

  defp review_prompt(ticket, diff) do
    """
    You are reviewing a branch before it lands on main. You are in a checkout of it, already
    rebased onto main; read any file you need. Its ticket:

    ##{ticket.id} #{ticket.title}
    #{ticket.body}

    Look for what would make this wrong to land: a correctness bug, a broken behaviour, a test that
    does not test what it claims, a rule in the repo's AGENTS.md or CLAUDE.md it breaks. Ask for
    changes only for those, not for style or taste. Say each finding with its file and line and
    why it is wrong.

    End with one line, exactly `VERDICT: approve` or `VERDICT: request_changes`.

    The diff against main:

    #{diff}
    """
  end

  defp land(dir, tries) do
    with :ok <- ok(git(dir, ["fetch", "-q", "origin", "main"]), "could not fetch origin's main"),
         :ok <- caught_up(dir) do
      case git(dir, ["push", "-q", "origin", "HEAD:refs/heads/main"]) do
        {_, 0} ->
          {sha, 0} = git(dir, ["rev-parse", "HEAD"])
          {:landed, String.trim(sha)}

        {_, _} when tries > 1 ->
          land(dir, tries - 1)

        {out, _} ->
          {:failed, "main would not take the push.\n" <> tail(out)}
      end
    end
  end

  # main moved since the gate ran: what lands is what was gated, so rebase and gate again
  defp caught_up(dir) do
    case git(dir, ["merge-base", "--is-ancestor", "origin/main", "HEAD"]) do
      {_, 0} -> :ok
      _ -> with :ok <- onto_main(dir), do: gate(dir)
    end
  end

  defp git(dir, args), do: System.cmd("git", ["-C", dir | args], stderr_to_stdout: true, env: clean_env())

  defp cmd([exe | args], dir, opts) do
    args = ["#{opts[:timeout]}", exe | args]

    argv =
      case opts[:stdin] do
        nil -> ["timeout" | args]
        file -> ["sh", "-c", ~S(f=$1; shift; exec "$@" < "$f"), "sh", file, "timeout" | args]
      end

    [bin | rest] = argv
    System.cmd(bin, rest, cd: dir, stderr_to_stdout: true, env: clean_env() ++ Keyword.get(opts, :env, []))
  end

  # the release's own variables would point a gate's mix or erl at babylon's runtime
  defp clean_env do
    for {key, _} <- System.get_env(),
        String.starts_with?(key, ["RELEASE_", "ERL_", "BABYLON_"]) or key in ~w(BINDIR ROOTDIR EMU PROGNAME),
        do: {key, nil}
  end

  defp ok({_, 0}, _why), do: :ok
  defp ok({out, _}, why), do: {:failed, why <> ".\n" <> tail(out)}

  defp tail(out), do: out |> String.split("\n") |> Enum.take(-@tail_lines) |> Enum.join("\n") |> String.trim()

  defp conf(key), do: :babylon |> Application.fetch_env!(:pipeline) |> Keyword.fetch!(key)
end
