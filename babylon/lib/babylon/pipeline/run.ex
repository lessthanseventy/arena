defmodule Babylon.Pipeline.Run do
  @moduledoc """
  A ticket's way to main, in a worktree of its repo: rebased onto main, its repo's gate run,
  reviewed headlessly, then pushed as main's new head; or several of a repo's at once as a merge
  train (`train/2`), reviewed apart and gated together. Main moving meanwhile means another
  rebase and gate before the push, which only a fast-forward passes.
  """
  alias Babylon.Ticket

  @diff_limit 200_000
  @tail_lines 40
  @fix_limit 60

  @marker ~r/^(<{7}|={7}|>{7}|\|{7})( |$)/m

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
         :ok <- onto_main(dir, ticket),
         :ok <- ahead(dir),
         :ok <- gate(dir, ticket),
         :ok <- stage.("reviewing"),
         {:ok, fixed} <- review(dir, ticket),
         :ok <- regate(dir, ticket, fixed),
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

  @doc """
  Remove `branch`'s worktree in repo `name` and the branch, unless a pane in `paths` is in it, it
  has uncommitted changes, or a commit on it is not on main.
  """
  @spec tidy(String.t(), String.t(), [String.t()]) :: :removed | :absent | {:kept, String.t()}
  def tidy(name, branch, paths) do
    repo = Path.join(conf(:projects), name)

    with {:ok, dir} <- worktree_of(repo, branch),
         :ok <- unoccupied(dir, paths),
         :ok <- committed(dir),
         :ok <- landed(repo, branch),
         {_, 0} <- git(repo, ["worktree", "remove", dir]),
         {_, 0} <- git(repo, ["branch", "-D", branch]) do
      :removed
    else
      :absent -> :absent
      {:kept, _} = kept -> kept
      {out, _} -> {:kept, String.trim(out)}
    end
  end

  defp answers({out, 0}, out, _why), do: :ok
  defp answers(_, _, why), do: {:skipped, why}

  @doc """
  Take several of one repo's `tickets` through as a train: each rebased onto main and reviewed on
  its own, side by side; those the review passes stacked one on another and gated once, landing
  together when it is green. A red train is split in half and each half gated, so the green ones
  land and only the one at fault goes back. `stage` is called with a ticket's id and each stage.
  """
  @spec train([Ticket.t()], (pos_integer(), String.t() -> :ok)) :: [{pos_integer(), Babylon.Pipeline.outcome()}]
  def train([first | _] = tickets, stage) do
    repo = Path.join(conf(:projects), first.repo)

    # worktrees are made and removed one at a time, as git locks the repo for each; the reviews
    # in them run side by side
    set_up = for ticket <- tickets, do: {ticket, review_dir(ticket), fresh(repo, review_dir(ticket), ticket.branch)}

    reviews =
      set_up
      |> Task.async_stream(&reviewed(&1, stage), timeout: :infinity, max_concurrency: length(tickets), ordered: true)
      |> Enum.zip(set_up)
      |> Enum.map(fn
        {{:ok, result}, _} -> result
        {{:exit, reason}, {ticket, _, _}} -> {ticket, {:failed, "its review crashed: #{inspect(reason)}"}}
      end)

    for {_, dir, _} <- set_up, do: git(repo, ["worktree", "remove", "--force", dir])
    {ready, refused} = Enum.split_with(reviews, &match?({_, {:ok, _, _}}, &1))

    for({ticket, failed} <- refused, do: {ticket.id, failed}) ++
      together(repo, for({ticket, {:ok, range, fixed}} <- ready, do: {ticket, range, fixed}), stage, 3)
  end

  defp review_dir(ticket), do: Path.join(conf(:work), "#{ticket.repo}.t#{ticket.id}")

  defp reviewed({ticket, _dir, {:failed, _} = failed}, _stage), do: {ticket, failed}

  defp reviewed({ticket, dir, :ok}, stage) do
    stage.(ticket.id, "reviewing")

    result =
      with :ok <- onto_main(dir, ticket),
           :ok <- ahead(dir),
           {:ok, fixed} <- review(dir, ticket) do
        {:ok, {rev(dir, "origin/main"), rev(dir, "HEAD")}, fixed}
      end

    {ticket, result}
  end

  defp fresh(repo, dir, branch) do
    File.rm_rf(dir)
    git(repo, ["worktree", "prune"])
    File.mkdir_p(Path.dirname(dir))

    case git(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"]) do
      {_, 0} -> ok(git(repo, ["worktree", "add", "-q", "--detach", dir, branch]), "could not check it out")
      _ -> {:failed, "there is no branch #{branch} in #{repo}: commit the work on it first"}
    end
  end

  defp rev(dir, ref), do: dir |> git(["rev-parse", ref]) |> elem(0) |> String.trim()

  defp together(_repo, [], _stage, _tries), do: []

  defp together(repo, [{first, _, _} | _] = cars, stage, tries) do
    dir = Path.join(conf(:work), first.repo)

    case stack(repo, dir, cars) do
      {[], refused} -> refused
      {stacked, refused} -> refused ++ gated(repo, dir, stacked, stage, tries)
    end
  end

  # main's head with each car's reviewed commits picked on in turn; one that will not pick goes back
  defp stack(repo, dir, [{first, _, _} | _] = cars) do
    with :ok <- checkout(repo, dir, first.branch),
         :ok <- ok(git(dir, ["fetch", "-q", "origin", "main"]), "could not fetch origin's main"),
         :ok <- ok(git(dir, ["checkout", "-q", "--detach", "origin/main"]), "could not check out main") do
      Enum.reduce(cars, {[], []}, &pick(dir, &1, &2))
    else
      failed -> {[], for({ticket, _, _} <- cars, do: {ticket.id, failed})}
    end
  end

  defp pick(dir, {ticket, {base, tip}, _} = car, {stacked, refused}) do
    # a commit the stack has already, as from a branch built on another in the train, picks empty
    picked =
      case git(dir, ["cherry-pick", "--empty=drop", "#{base}..#{tip}"]) do
        {_, 0} -> :ok
        _ -> resolved(dir, ticket, "cherry-pick")
      end

    case picked do
      :ok ->
        {stacked ++ [car], refused}

      :error ->
        git(dir, ["cherry-pick", "--abort"])
        ahead = Enum.map_join(stacked, ", ", fn {t, _, _} -> "##{t.id}" end)
        {stacked, refused ++ [{ticket.id, {:failed, "it does not stack cleanly on main with #{ahead}"}}]}
    end
  end

  defp gated(repo, dir, [{first, _, _} | _] = stacked, stage, tries) do
    for {ticket, _, _} <- stacked, do: stage.(ticket.id, "verifying")

    case {gate(dir, first), stacked} do
      {:ok, _} ->
        for {ticket, _, _} <- stacked, do: stage.(ticket.id, "landing")
        pushed(repo, dir, stacked, stage, tries)

      {failed, [_]} ->
        [{first.id, failed}]

      {_, _} ->
        {front, back} = Enum.split(stacked, div(length(stacked), 2))
        together(repo, front, stage, tries) ++ together(repo, back, stage, tries)
    end
  end

  # main moved since the stack was made: restacked on it and gated again, split on red as before
  defp pushed(repo, dir, stacked, stage, tries) do
    case land_gated(dir) do
      {:landed, _} = landed ->
        for {ticket, _, fixed} <- stacked, do: {ticket.id, with_fixes(landed, fixed)}

      :moved when tries > 1 ->
        together(repo, stacked, stage, tries - 1)

      :moved ->
        for {ticket, _, _} <- stacked, do: {ticket.id, {:failed, "main kept moving under the train"}}

      {:failed, _} = failed ->
        for {ticket, _, _} <- stacked, do: {ticket.id, failed}
    end
  end

  defp land_gated(dir) do
    with :ok <- ok(git(dir, ["fetch", "-q", "origin", "main"]), "could not fetch origin's main") do
      case git(dir, ["merge-base", "--is-ancestor", "origin/main", "HEAD"]) do
        {_, 0} -> push(dir)
        _ -> :moved
      end
    end
  end

  defp push(dir) do
    case git(dir, ["push", "-q", "origin", "HEAD:refs/heads/main"]) do
      {_, 0} -> {:landed, rev(dir, "HEAD")}
      _ -> :moved
    end
  end

  defp with_fixes({:landed, sha}, [_ | _] = fixed), do: {:landed, sha, Enum.join(fixed, "; ")}
  defp with_fixes(outcome, _fixed), do: outcome

  # one worktree a repo, kept between runs so its builds and deps stay warm
  defp checkout(repo, dir, branch) do
    stop_gate(Path.basename(dir))

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

  defp onto_main(dir, ticket) do
    with :ok <- ok(git(dir, ["fetch", "-q", "origin", "main"]), "could not fetch origin's main") do
      case git(dir, ["rebase", "-q", "origin/main"]) do
        {_, 0} -> :ok
        _ -> rebase_resolved(dir, ticket, conflicted(dir))
      end
    end
  end

  defp rebase_resolved(dir, ticket, conflicts) do
    with :error <- resolved(dir, ticket, "rebase") do
      git(dir, ["rebase", "--abort"])
      {:failed, "it does not rebase onto main cleanly; conflicts in: " <> Enum.join(conflicts, ", ")}
    end
  end

  defp conflicted(dir) do
    {out, _} = git(dir, ["diff", "--name-only", "--diff-filter=U"])
    String.split(out)
  end

  # A rebase or cherry-pick stopped on a conflict is handed to the reviewer's command to resolve in
  # place, a step at a time. Its resolution is kept only when it says RESOLVED, leaves no marker,
  # and changes at most @fix_limit lines past dropping the markers; it is then gated as any change.
  defp resolved(dir, ticket, op, steps \\ 5)
  defp resolved(_dir, _ticket, _op, 0), do: :error

  defp resolved(dir, ticket, op, steps) do
    files = conflicted(dir)
    marked = Map.new(files, &{&1, read(dir, &1)})

    # a file deleted on one side has no markers to resolve: that is a decision, sent back
    if Enum.all?(Map.values(marked), &(is_binary(&1) and markers?(&1))),
      do: resolve(dir, ticket, op, steps, marked),
      else: :error
  end

  defp resolve(dir, ticket, op, steps, marked) do
    files = Map.keys(marked)
    prompt = dir <> ".resolve"
    File.write!(prompt, resolve_prompt(ticket, files))
    named = conf(:reviewer) ++ ["--name", "babylon resolve · #{ticket.repo} ##{ticket.id}"]

    try do
      with {out, 0} <- cmd(named, dir, timeout: conf(:review_timeout), stdin: prompt),
           true <- out =~ ~r/^RESOLVED\s*$/m,
           true <- kept_to(dir, marked),
           :ok <- stage_resolution(dir, ticket, files) do
        case git(dir, ["-c", "core.editor=true", op, "--continue"]) do
          {_, 0} -> :ok
          _ -> if conflicted(dir) == [], do: :error, else: resolved(dir, ticket, op, steps - 1)
        end
      else
        _ -> :error
      end
    after
      File.rm(prompt)
    end
  end

  # every conflicted file there, its markers gone, the lines changed past them under the limit, and
  # nothing touched outside them
  defp kept_to(dir, marked) do
    now = Map.new(marked, fn {file, _} -> {file, read(dir, file)} end)
    {unstaged, _} = git(dir, ["diff", "--name-only"])
    {untracked, _} = git(dir, ["ls-files", "--others", "--exclude-standard"])

    Enum.all?(Map.values(now), &(is_binary(&1) and not markers?(&1))) and
      Enum.sum(for {file, before} <- marked, do: changed(before, now[file])) <= @fix_limit and
      Enum.all?(String.split(unstaged <> "\n" <> untracked), &Map.has_key?(marked, &1))
  end

  defp read(dir, file) do
    case File.read(Path.join(dir, file)) do
      {:ok, text} -> text
      {:error, _} -> nil
    end
  end

  defp markers?(text), do: Regex.match?(@marker, text)

  defp changed(before, now) do
    kept = before |> String.split("\n") |> Enum.reject(&Regex.match?(@marker, &1))

    for {op, lines} <- List.myers_difference(kept, String.split(now, "\n")), op != :eq, reduce: 0 do
      acc -> acc + length(lines)
    end
  end

  # the --continue that follows commits it, with the picked commit's message and a line saying so
  # a cherry-pick takes it from MERGE_MSG, a rebase from rebase-merge/message
  defp stage_resolution(dir, ticket, files) do
    resolved = "Conflict resolved for ##{ticket.id}: #{Enum.join(files, ", ")}"

    for name <- ["MERGE_MSG", "rebase-merge/message"],
        {path, 0} = git(dir, ["rev-parse", "--git-path", name]),
        msg = Path.expand(String.trim(path), dir),
        File.exists?(msg) do
      {was, _} = msg |> File.read!() |> String.split("\n") |> Enum.split_while(&(&1 != "# Conflicts:"))
      File.write!(msg, String.trim(Enum.join(was, "\n")) <> "\n\n" <> resolved <> "\n")
    end

    ok(git(dir, ["add", "--" | files]), "could not stage the resolution")
  end

  defp resolve_prompt(ticket, files) do
    """
    You are in a checkout stopped on a conflict while putting this ticket's branch onto main:

    ##{ticket.id} #{ticket.title}
    #{ticket.body}

    The conflicted files, with git's markers in them: #{Enum.join(files, ", ")}. Resolve each with
    Edit so both sides' intent is kept: main's change and the ticket's, as when both add an entry
    in the same spot (keep both, in a sensible order). Remove every marker. Change nothing past
    the conflicted hunks, and no more than #{@fix_limit} lines in all.

    If both sides cannot be kept (they change the same thing different ways, or keeping both
    needs a decision), edit nothing.

    End with one line, exactly one of:
    - `RESOLVED`: no marker is left and both sides are kept.
    - `UNRESOLVED`: you could not, and changed nothing.
    """
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

    case {code, unstarted(out)} do
      {0, _} ->
        :ok

      {124, _} ->
        {:failed, "the gate ran past #{minutes} minutes; its output is in #{log}"}

      {_, nil} ->
        {:failed, "the gate is red (exit #{code}); its whole output is in #{log}\n" <> failing(out)}

      {_, line} ->
        {:failed,
         "the gate could not start in babylon's worktree: " <>
           "#{String.trim(line)}. That is the repo's setup to fix (see babylon's README, Join it), " <>
           "not this ticket's; its whole output is in #{log}"}
    end
  end

  # a line saying the gate's tools or deps were missing, not that the change failed
  defp unstarted(out) do
    Enum.find(String.split(out, "\n"), fn line ->
      bare = Regex.replace(~r/^\s*\[[^\]]*\]\s*/, line, "")

      Enum.any?(conf(:unstarted), fn [start, within] ->
        String.starts_with?(bare, start) and String.contains?(bare, within)
      end)
    end)
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
  # a gate left running in the warm worktree, as by a babylon restarted under it, would race this
  # one there: it goes first, with every process of its pane's session
  defp stop_gate(name) do
    case tmux(["list-panes", "-s", "-t", "=babylon", "-F", "\#{window_name} \#{pane_pid} \#{window_id}"]) do
      {listed, 0} ->
        for [^name, pid, window] <- Enum.map(String.split(listed, "\n", trim: true), &String.split(&1, " ")) do
          System.cmd("pkill", ["-KILL", "-s", pid], stderr_to_stdout: true)
          tmux(["kill-window", "-t", window])
        end

      _ ->
        :ok
    end
  end

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
             do: {:ok, fixed}
    end
  end

  defp kept(verdict, dir, _ticket, _out) do
    discard(dir)
    verdict
  end

  # a lone ticket was gated before its review: the review's fixes are gated again
  defp regate(_dir, _ticket, []), do: :ok
  defp regate(dir, ticket, _fixed), do: gate(dir, ticket)

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
      _ -> with :ok <- onto_main(dir, ticket), do: gate(dir, ticket)
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

  defp worktree_of(repo, branch) do
    {out, _} = git(repo, ["worktree", "list", "--porcelain"])

    out
    |> String.split("\n\n", trim: true)
    |> Enum.map(&String.split(&1, "\n"))
    |> Enum.find_value(:absent, fn
      ["worktree " <> dir | rest] -> "branch refs/heads/#{branch}" in rest and {:ok, dir}
      _ -> nil
    end)
  end

  defp unoccupied(dir, paths) do
    if Enum.any?(paths, &(&1 == dir or String.starts_with?(&1, dir <> "/"))),
      do: {:kept, "a session is in it"},
      else: :ok
  end

  defp committed(dir) do
    case git(dir, ["status", "--porcelain"]) do
      {"", 0} -> :ok
      _ -> {:kept, "it has uncommitted changes"}
    end
  end

  # by patch, as babylon rebased what it landed
  defp landed(repo, branch) do
    git(repo, ["fetch", "-q", "origin", "main"])

    case git(repo, ["cherry", "origin/main", branch]) do
      {out, 0} -> if String.contains?(out, "+ "), do: {:kept, "it has commits not on main"}, else: :ok
      {out, _} -> {:kept, String.trim(out)}
    end
  end
end
