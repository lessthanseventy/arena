defmodule Babylon.Pipeline.Run do
  @moduledoc """
  One ticket's way to main, in a throwaway worktree of its repo: rebased onto main, its repo's gate
  run, reviewed headlessly, then pushed as main's new head. Main moving meanwhile means another
  rebase and gate before the push, which only a fast-forward passes.
  """
  alias Babylon.Ticket

  @diff_limit 200_000
  @tail_lines 40
  @fix_limit 60

  @doc """
  Take `ticket` through, calling `stage` with each stage as it starts. `{:landed, sha}`, or
  `{:failed, why}` at the first step that refuses it.
  """
  @spec run(Ticket.t(), (String.t() -> :ok)) :: Babylon.Pipeline.outcome()
  def run(%Ticket{} = ticket, stage) do
    repo = Path.join(conf(:projects), ticket.repo)
    dir = Path.join(conf(:work), ticket.repo)

    with :ok <- stage.("verifying"),
         :ok <- checkout(repo, dir, ticket.branch),
         :ok <- onto_main(dir),
         :ok <- ahead(dir),
         :ok <- gate(dir, ticket),
         :ok <- stage.("reviewing"),
         {:ok, fixed} <- review(dir, ticket),
         :ok <- stage.("landing"),
         {:landed, sha} <- land(dir, ticket, 3) do
      if fixed == [], do: {:landed, sha}, else: {:landed, sha, Enum.join(fixed, "; ")}
    end
  end

  @doc """
  Bring `name`'s own checkout up to origin's main, when it is on main with nothing changed, and
  start its `install` task, if it has one, in a window of babylon's tmux session. Not waited on:
  installing babylon restarts it. `{:ok, log}`, or `{:skipped, why}` with the checkout untouched.
  """
  @spec install(String.t()) :: {:ok, String.t()} | {:skipped, String.t()}
  def install(name) do
    repo = Path.join(conf(:projects), name)
    log = Path.join([Path.dirname(conf(:work)), "logs", "#{name}-install.log"])

    with :ok <- answers(git(repo, ["branch", "--show-current"]), "main\n", "its checkout is not on main"),
         :ok <- answers(git(repo, ["status", "--porcelain", "--untracked-files=no"]), "", "its checkout has changes"),
         :ok <- answers(git(repo, ["fetch", "-q", "origin", "main"]), "", "could not fetch origin's main"),
         :ok <- answers(git(repo, ["merge", "-q", "--ff-only", "origin/main"]), "", "its main would not fast-forward") do
      File.mkdir_p!(Path.dirname(log))
      script = "{ mise tasks info install >/dev/null 2>&1 && mise run install; } >#{sh_quote(log)} 2>&1; read _"
      open_window("#{name}-install", ["-d", "-c", repo, "-e", "MISE_TRUSTED_CONFIG_PATHS=#{repo}", "sh", "-c", script])
      {:ok, log}
    end
  end

  defp answers({out, 0}, out, _why), do: :ok
  defp answers(_, _, why), do: {:skipped, why}

  # one worktree a repo, kept between runs so its builds and deps stay warm
  defp checkout(repo, dir, branch) do
    cond do
      not File.dir?(repo) ->
        {:failed, "there is no checkout of it at #{repo}"}

      not match?({_, 0}, git(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"])) ->
        {:failed, "there is no branch #{branch} in #{repo}: commit the work on it first"}

      match?({_, 0}, git(dir, ["rev-parse", "--git-dir"])) and File.exists?(Path.join(dir, ".git")) ->
        git(dir, ["rebase", "--abort"])

        with :ok <- ok(git(dir, ["checkout", "-q", "--force", "--detach", branch]), "could not check it out") do
          ok(git(dir, ["clean", "-fdq"]), "could not clean its worktree")
        end

      true ->
        File.rm_rf!(dir)
        git(repo, ["worktree", "prune"])
        File.mkdir_p!(Path.dirname(dir))

        with :ok <- ok(git(repo, ["worktree", "add", "-q", "--detach", dir, branch]), "could not check it out") do
          seed(dir)
        end
    end
  end

  # the main checkout's builds and deps its .worktreeinclude names, so even the first gate is not cold
  defp seed(dir) do
    if System.find_executable("wt"),
      do: System.cmd("wt", ["-C", dir, "step", "copy-ignored", "--require-include"], stderr_to_stdout: true)

    :ok
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

  defp gate(dir, ticket) do
    minutes = div(conf(:gate_timeout), 60)
    log = Path.join([Path.dirname(conf(:work)), "logs", "#{ticket.repo}-t#{ticket.id}.log"])
    {out, code} = in_window(dir, ticket, log)

    case code do
      0 -> :ok
      124 -> {:failed, "the gate ran past #{minutes} minutes; its output is in #{log}"}
      _ -> {:failed, "the gate is red (exit #{code}); its whole output is in #{log}\n" <> failing(out)}
    end
  end

  # The gate runs in a window of babylon's own tmux session, to be watched as it goes and read after;
  # its exit and output come back through files, and its end through a tmux wait-for channel.
  defp in_window(dir, ticket, log) do
    exit_file = log <> ".exit"
    File.mkdir_p!(Path.dirname(log))
    File.rm(exit_file)
    File.write!(log, "")
    channel = "babylon-#{ticket.repo}-#{ticket.id}-#{System.unique_integer([:positive])}"
    gate = Enum.map_join(["timeout", "#{conf(:gate_timeout)}" | conf(:gate)], " ", &sh_quote/1)

    script =
      "(#{gate}; echo $? > #{sh_quote(exit_file)}) 2>&1 | tee #{sh_quote(log)}; " <>
        "tmux #{Enum.map_join(conf(:tmux), " ", &sh_quote/1)} wait-for -S #{channel}; read _"

    open_window(ticket.repo, ["-d", "-c", dir, "-e", "MISE_TRUSTED_CONFIG_PATHS=#{dir}", "sh", "-c", script])
    tmux(["wait-for", channel], conf(:gate_timeout) + 60)

    case File.read(exit_file) do
      {:ok, code} -> {File.read!(log), code |> String.trim() |> String.to_integer()}
      {:error, _} -> {File.read!(log) <> "\nthe gate's window closed before it finished", 1}
    end
  end

  # the last window of that name goes once the new one is open, as the session ends with its last window
  defp open_window(name, opened) do
    opened = ["-n", name | opened]

    case tmux(["list-windows", "-t", "=babylon", "-F", "\#{window_id} \#{window_name}"]) do
      {listed, 0} ->
        tmux(["new-window", "-t", "=babylon:" | opened])

        for [id, ^name] <- Enum.map(String.split(listed, "\n", trim: true), &String.split(&1, " ", parts: 2)),
            do: tmux(["kill-window", "-t", id])

      _ ->
        # another lane may make the session first: then this window goes into it
        with {_, code} when code != 0 <- tmux(["new-session", "-s", "babylon" | opened]),
             do: tmux(["new-window", "-t", "=babylon:" | opened])
    end
  end

  defp tmux(args, timeout \\ 10) do
    System.cmd("timeout", ["#{timeout}", "tmux" | conf(:tmux) ++ args], stderr_to_stdout: true, env: clean_env())
  end

  defp sh_quote(word), do: "'" <> String.replace(word, "'", ~S('\'')) <> "'"

  # what failed first, as a gate's own summary can come long after it
  defp failing(out) do
    lines = String.split(out, "\n")
    failed = Enum.filter(lines, &Regex.match?(~r/\bFAIL|\bERROR|\*\* \(|\berror:|\bfailed\b/i, &1))

    case Enum.take(failed, 20) do
      [] -> tail(out)
      first -> Enum.join(first ++ ["…", tail(out)], "\n")
    end
  end

  defp review(dir, ticket) do
    # what the gate left behind is not the reviewer's to commit
    discard(dir)
    {diff, 0} = git(dir, ["diff", "origin/main...HEAD"])
    prompt = dir <> ".review"
    File.write!(prompt, review_prompt(ticket, String.slice(diff, 0, @diff_limit)))

    try do
      named = conf(:reviewer) ++ ["--name", "babylon review · #{ticket.repo} ##{ticket.id}"]

      case cmd(named, dir, timeout: conf(:review_timeout), stdin: prompt) do
        {out, 0} -> out |> verdict() |> kept(dir, ticket, out)
        {_, 124} -> {:failed, "the review ran past #{div(conf(:review_timeout), 60)} minutes"}
        {out, code} -> {:failed, "the reviewer failed (exit #{code}).\n" <> tail(out)}
      end
    after
      File.rm(prompt)
    end
  end

  defp verdict(out) do
    case Regex.scan(~r/^VERDICT: (approve|fix|request_changes)\s*$/m, out) do
      [] ->
        {:failed, "the review gave no verdict.\n" <> tail(out)}

      found ->
        case List.last(found) do
          [_, "approve"] -> {:ok, []}
          [_, "fix"] -> {:fix, for([_, line] <- Regex.scan(~r/^FIXED: (.+?)\s*$/m, out), do: line)}
          [_, "request_changes"] -> {:failed, "the review asked for changes.\n" <> String.trim(out)}
        end
    end
  end

  # The reviewer's own edits are kept only with a fix verdict, small enough to be one, committed
  # and gated again; any other verdict leaves the branch as it came.
  defp kept({:fix, []}, dir, _ticket, out) do
    discard(dir)
    {:failed, "the review said fix but named no FIXED line; its findings:\n" <> String.trim(out)}
  end

  defp kept({:fix, fixed}, dir, ticket, out) do
    git(dir, ["add", "-A"])
    {stat, 0} = git(dir, ["diff", "--cached", "--numstat"])

    changed =
      for line <- String.split(stat, "\n", trim: true),
          [added, removed | _] = String.split(line, "\t"),
          reduce: 0,
          do: (acc -> acc + count(added) + count(removed))

    cond do
      changed == 0 ->
        {:failed, "the review said it fixed its findings but changed nothing; its findings:\n" <> String.trim(out)}

      changed > @fix_limit ->
        discard(dir)
        {:failed, "the review's fixes ran to #{changed} lines, more than a fix; its findings:\n" <> String.trim(out)}

      true ->
        message = "Review fixes for ##{ticket.id}\n\n" <> Enum.map_join(fixed, "\n", &("- " <> &1))

        with :ok <- ok(git(dir, ["commit", "-q", "-m", message]), "could not commit the review's fixes"),
             :ok <- gate(dir, ticket),
             do: {:ok, fixed}
    end
  end

  defp kept(verdict, dir, _ticket, _out) do
    discard(dir)
    verdict
  end

  defp discard(dir) do
    git(dir, ["reset", "-q", "--hard"])
    git(dir, ["clean", "-fdq"])
  end

  defp count("-"), do: 1
  defp count(n), do: String.to_integer(n)

  defp review_prompt(ticket, diff) do
    """
    You are reviewing a branch before it lands on main. You are in a checkout of it, already
    rebased onto main; read any file you need. Its ticket:

    ##{ticket.id} #{ticket.title}
    #{ticket.body}

    Look for what would make this wrong to land: a correctness bug, a broken behaviour, a test that
    does not test what it claims, a rule in the repo's AGENTS.md or CLAUDE.md it breaks. Not style
    or taste. Say each finding with its file and line and why it is wrong.

    A finding that is small and mechanical (a typo, a missing separator, a stray blank line, a
    stale comment or name, a wrong string in a test) fix yourself with Edit in this checkout, and
    say each as one line `FIXED: <file>:<line> <what>`. All your fixes together stay under
    #{@fix_limit} changed lines. They are committed and gated again, not reviewed again. Anything
    that changes behaviour, an interface, or what a test means is not yours to fix: ask for
    changes, and leave the files alone.

    End with one line, exactly one of:
    - `VERDICT: approve`: nothing to change.
    - `VERDICT: fix`: you fixed every finding yourself.
    - `VERDICT: request_changes`: a finding is not yours to fix (any fixes you made are dropped).

    The diff against main:

    #{diff}
    """
  end

  defp land(dir, ticket, tries) do
    with :ok <- ok(git(dir, ["fetch", "-q", "origin", "main"]), "could not fetch origin's main"),
         :ok <- caught_up(dir, ticket) do
      case git(dir, ["push", "-q", "origin", "HEAD:refs/heads/main"]) do
        {_, 0} ->
          {sha, 0} = git(dir, ["rev-parse", "HEAD"])
          {:landed, String.trim(sha)}

        {_, _} when tries > 1 ->
          land(dir, ticket, tries - 1)

        {out, _} ->
          {:failed, "main would not take the push.\n" <> tail(out)}
      end
    end
  end

  # main moved since the gate ran: what lands is what was gated, so rebase and gate again
  defp caught_up(dir, ticket) do
    case git(dir, ["merge-base", "--is-ancestor", "origin/main", "HEAD"]) do
      {_, 0} -> :ok
      _ -> with :ok <- onto_main(dir), do: gate(dir, ticket)
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
