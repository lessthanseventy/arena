defmodule Babylon.Pipeline do
  @moduledoc """
  How a finished ticket's branch reaches main: verified (rebased onto main and its repo's gate run),
  reviewed headlessly, then landed by fast-forward. Each repo has one lane, taking its tickets in
  the order submitted: a lone one goes through by itself, several (up to `:train`) as a merge
  train (`Babylon.Pipeline.Run.train/2`). Different repos run side by side, no more than the
  `:gates` the config allows at once. The session holding the ticket is told how it went: landed, the ticket is done; sent
  back, it is `doing` again with why in `stage_note`, or `todo` when that session is gone.
  """
  use GenServer

  import Ecto.Query

  alias Babylon.Panes
  alias Babylon.Pipeline.Run
  alias Babylon.Repo
  alias Babylon.Ticket
  alias Babylon.Tickets

  require Logger

  @running ~w(verifying reviewing landing)

  @type note :: {:fixed, String.t()} | {:followup, String.t()}
  @type outcome :: {:landed, String.t()} | {:landed, String.t(), [note()]} | {:failed, String.t()}

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Queue ticket `id`, which `pane` holds, to be verified, reviewed and landed."
  @spec submit(pos_integer(), String.t()) :: {:ok, Ticket.t()} | {:error, String.t()}
  def submit(id, pane) do
    case Repo.get(Ticket, id) do
      nil -> {:error, "no ticket ##{id}"}
      %Ticket{claimed_by: ^pane} = ticket -> queue(ticket)
      %Ticket{} -> {:error, "ticket ##{id} is not held by this pane: claim it first"}
    end
  end

  @doc "Make queued ticket `id` the next to run, ahead of every other queued ticket."
  @spec bump(pos_integer()) :: {:ok, Ticket.t()} | {:error, String.t()}
  def bump(id) do
    case Repo.get(Ticket, id) do
      %Ticket{stage: "queued"} = ticket ->
        first = Repo.one(from t in Ticket, where: t.stage == "queued", select: min(t.submitted_at))
        ahead = DateTime.add(first, -1, :second)
        {:ok, ticket |> Ecto.Changeset.change(submitted_at: ahead) |> Repo.update!()}

      %Ticket{} ->
        {:error, "ticket ##{id} is not queued"}

      nil ->
        {:error, "no ticket ##{id}"}
    end
  end

  @doc """
  Settle ticket `id` on its `outcome`, and tell the session holding it. `panes` is the set running
  Claude (`Babylon.Panes.claude/0`): a ticket sent back to a pane not among them goes to `todo`.
  A landing starts the repo's install, unless `installed` says how the train's one went.
  """
  @spec finish(pos_integer(), outcome(), Babylon.Claims.panes(), String.t() | nil) :: Ticket.t()
  def finish(id, outcome, panes, installed \\ nil)
  def finish(id, {:landed, sha}, _panes, installed), do: landed(id, sha, [], installed)

  def finish(id, {:landed, sha, notes}, _panes, installed), do: landed(id, sha, notes, installed)

  def finish(id, {:failed, why}, panes, _installed) do
    ticket = Repo.get!(Ticket, id)
    here = ticket.claimed_by != nil and (panes == :unknown or MapSet.member?(panes, ticket.claimed_by))

    back =
      if here,
        do: [status: "doing"],
        else: [status: "todo", claimed_by: nil, claimed_at: nil, labels: Enum.uniq(ticket.labels ++ ["sent back"])]

    sent = ticket |> Ecto.Changeset.change([stage: "failed", stage_note: why] ++ back) |> Repo.update!()
    Tickets.refresh_epic(Tickets.epic_of(id))
    [first | _] = String.split(why, "\n")
    Babylon.Notice.show("##{id} sent back: #{first}")

    if here do
      tell(
        sent,
        "##{id} was sent back: #{first} get_ticket #{id} has the whole of it in stage_note. " <>
          "Fix it on #{sent.branch}, commit, and submit_ticket #{id} again. If the fix goes past what " <>
          "the ticket's body says, update_ticket the body first: the review reads the ticket."
      )
    end

    sent
  end

  @impl true
  def init(nil) do
    Repo.update_all(from(t in Ticket, where: t.stage in @running), set: [stage: "queued"])
    {:ok, %{}, {:continue, :next}}
  end

  @impl true
  def handle_continue(:next, running), do: {:noreply, start(running)}

  # running: each run's task ref to its tickets' ids and their repo
  @impl true
  def handle_info(:next, running), do: {:noreply, start(running)}

  def handle_info({ref, outcome}, running) when is_map_key(running, ref) do
    Process.demonitor(ref, [:flush])
    settle(running, ref, outcome)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, running) when is_map_key(running, ref) do
    {ids, _repo} = running[ref]
    crashed = {:failed, "babylon's pipeline crashed on it: #{inspect(reason)}"}
    settle(running, ref, for(id <- ids, do: {id, crashed}))
  end

  defp settle(running, ref, outcomes) do
    {{_ids, repo}, running} = Map.pop!(running, ref)
    panes = Panes.claude()
    # one install for a train, however many of it landed
    installed =
      if Enum.any?(outcomes, &(match?({_, {:landed, _}}, &1) or match?({_, {:landed, _, _}}, &1))), do: install(repo)

    for {id, outcome} <- outcomes do
      %Ticket{stage: stage} = finish(id, outcome, panes, installed)
      Logger.info("pipeline: ##{id} #{stage}")
    end

    {:noreply, start(running)}
  end

  defp start(running) do
    gates = conf(:gates)

    case map_size(running) < gates and next_up(for {_, {_, repo}} <- running, do: repo) do
      %Ticket{} = ticket ->
        train = [ticket | riders(ticket, conf(:train) - 1)]
        task = Task.Supervisor.async_nolink(Babylon.Tasks, fn -> ride(train) end)
        start(Map.put(running, task.ref, {Enum.map(train, & &1.id), ticket.repo}))

      _ ->
        running
    end
  end

  @doc "The ticket to run next: the first submitted of those queued in a repo not in `busy`."
  @spec next_up([String.t()]) :: Ticket.t() | nil
  def next_up(busy) do
    Repo.one(
      from t in Ticket,
        where: t.stage == "queued" and t.repo not in ^busy,
        order_by: [asc: t.submitted_at, asc: t.id],
        limit: 1
    )
  end

  defp stage(id, stage) do
    Repo.update_all(from(t in Ticket, where: t.id == ^id), set: [stage: stage])
    :ok
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp queue(%Ticket{status: "review", id: id}), do: {:error, "ticket ##{id} is in the pipeline already"}
  defp queue(%Ticket{repo: nil, id: id}), do: {:error, "ticket ##{id} has no repo to land in"}
  defp queue(%Ticket{status: status, id: id}) when status != "doing", do: {:error, "ticket ##{id} is #{status}"}

  defp queue(ticket) do
    queued =
      ticket
      |> Ecto.Changeset.change(status: "review", stage: "queued", stage_note: "", submitted_at: now())
      |> Repo.update!()

    if pid = GenServer.whereis(__MODULE__), do: send(pid, :next)
    {:ok, queued}
  end

  defp landed(id, sha, notes, installed) do
    {:ok, ticket} = Tickets.update(Repo.get!(Ticket, id), %{status: "done"})
    fixed = said(ticket, notes)
    note = "landed on main as #{sha}#{fixed}"
    done = ticket |> Ecto.Changeset.change(stage: "landed", stage_note: note) |> Repo.update!()
    short = String.slice(sha, 0, 7)
    Babylon.Notice.show("##{id} landed on main: #{done.title}")

    installed = installed || install(done.repo)

    tell(
      done,
      "##{id} landed on main as #{short}#{fixed}; #{installed}. babylon removes its worktree once no session is in it."
    )

    done
  end

  @doc """
  Remove the worktree and branch of each ticket landed in the last day, once no pane in `paths`
  is in it, it has nothing uncommitted and every commit on it is on main; the branches removed.
  """
  @spec tidy([String.t()] | :unknown) :: [String.t()]
  def tidy(:unknown), do: []

  def tidy(paths) do
    since = DateTime.add(DateTime.utc_now(), -1, :day)

    from(t in Ticket, where: t.stage == "landed" and not is_nil(t.branch) and t.closed_at > ^since)
    |> Repo.all()
    |> Enum.filter(&(Run.tidy(&1.repo, &1.branch, paths) == :removed))
    |> Enum.map(& &1.branch)
  end

  defp said(ticket, notes) do
    fixed = for {:fixed, line} <- notes, do: line
    followed = for {:followup, line} <- notes, do: follow_up(ticket, line)
    part(", with the review's fixes: ", fixed) <> part("; follow-ups filed: ", followed)
  end

  defp part(_lead, []), do: ""
  defp part(lead, items), do: lead <> Enum.join(items, "; ")

  defp follow_up(ticket, line) do
    [title | what] = String.split(line, ~r/\s+—\s+/, parts: 2)

    case Tickets.file(%{
           title: title,
           repo: ticket.repo,
           labels: ["follow-up"],
           body: "Found by babylon's review of ##{ticket.id}, which landed without it. #{Enum.join(what)}"
         }) do
      {:ok, filed} -> "##{filed.id} #{title}"
      {:error, _} -> "not filed, as written: #{line}"
    end
  end

  defp install(repo) do
    case Run.install(repo) do
      {:ok, log} -> "#{repo}'s checkout is on it, its install running (#{log})"
      {:skipped, why} -> "#{repo}'s checkout is left as it is: #{why}"
    end
  end

  defp tell(%Ticket{claimed_by: nil}, _text), do: :ok
  defp tell(%Ticket{claimed_by: pane}, text), do: Babylon.Inbox.send(pane, text)

  defp ride([ticket]), do: [{ticket.id, Run.run(ticket, &stage(ticket.id, &1))}]
  defp ride(train), do: Run.train(train, &stage/2)

  # the next queued tickets of the same repo, to go through with `ticket` as one train
  defp riders(_ticket, 0), do: []

  defp riders(ticket, n) do
    Repo.all(
      from t in Ticket,
        where: t.stage == "queued" and t.repo == ^ticket.repo and t.id != ^ticket.id,
        order_by: [asc: t.submitted_at, asc: t.id],
        limit: ^n
    )
  end

  defp conf(key), do: :babylon |> Application.fetch_env!(:pipeline) |> Keyword.fetch!(key)
end
