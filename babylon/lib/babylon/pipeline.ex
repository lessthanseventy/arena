defmodule Babylon.Pipeline do
  @moduledoc """
  How a finished ticket's branch reaches main: verified (rebased onto main and its repo's gate run),
  reviewed headlessly, then landed by fast-forward, one ticket at a time in the order they were
  submitted. The session holding the ticket is told how it went: landed, the ticket is done; sent
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

  @type outcome :: {:landed, String.t()} | {:landed, String.t(), String.t()} | {:failed, String.t()}

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

  @doc """
  Settle ticket `id` on its `outcome`, and tell the session holding it. `panes` is the set running
  Claude (`Babylon.Panes.claude/0`): a ticket sent back to a pane not among them goes to `todo`.
  """
  @spec finish(pos_integer(), outcome(), Babylon.Claims.panes()) :: Ticket.t()
  def finish(id, {:landed, sha}, _panes), do: landed(id, sha, "")
  def finish(id, {:landed, sha, fixed}, _panes), do: landed(id, sha, ", with the review's fixes: #{fixed}")

  def finish(id, {:failed, why}, panes) do
    ticket = Repo.get!(Ticket, id)
    here = ticket.claimed_by != nil and (panes == :unknown or MapSet.member?(panes, ticket.claimed_by))

    back =
      if here,
        do: [status: "doing"],
        else: [status: "todo", claimed_by: nil, claimed_at: nil, labels: Enum.uniq(ticket.labels ++ ["sent back"])]

    sent = ticket |> Ecto.Changeset.change([stage: "failed", stage_note: why] ++ back) |> Repo.update!()
    Tickets.refresh_epic(Tickets.epic_of(id))
    [first | _] = String.split(why, "\n")

    if here do
      tell(
        sent,
        "##{id} was sent back: #{first} get_ticket #{id} has the whole of it in stage_note. " <>
          "Fix it on #{sent.branch}, commit, and submit_ticket #{id} again."
      )
    end

    sent
  end

  @impl true
  def init(nil) do
    Repo.update_all(from(t in Ticket, where: t.stage in @running), set: [stage: "queued"])
    {:ok, nil, {:continue, :next}}
  end

  @impl true
  def handle_continue(:next, state), do: handle_info(:next, state)

  @impl true
  def handle_info(:next, nil) do
    case next() do
      nil ->
        {:noreply, nil}

      ticket ->
        task = Task.Supervisor.async_nolink(Babylon.Tasks, fn -> Run.run(ticket, &stage(ticket.id, &1)) end)
        {:noreply, {task.ref, ticket.id}}
    end
  end

  def handle_info(:next, busy), do: {:noreply, busy}

  def handle_info({ref, outcome}, {ref, id}) do
    Process.demonitor(ref, [:flush])
    settle(id, outcome)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, {ref, id}) do
    settle(id, {:failed, "babylon's pipeline crashed on it: #{inspect(reason)}"})
  end

  defp settle(id, outcome) do
    %Ticket{stage: stage} = finish(id, outcome, Panes.claude())
    Logger.info("pipeline: ##{id} #{stage}")
    send(self(), :next)
    {:noreply, nil}
  end

  defp next do
    Repo.one(from t in Ticket, where: t.stage == "queued", order_by: [asc: t.submitted_at, asc: t.id], limit: 1)
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

  defp landed(id, sha, fixed) do
    {:ok, ticket} = Tickets.update(Repo.get!(Ticket, id), %{status: "done"})
    note = "landed on main as #{sha}#{fixed}"
    done = ticket |> Ecto.Changeset.change(stage: "landed", stage_note: note) |> Repo.update!()
    short = String.slice(sha, 0, 7)
    tell(done, "##{id} landed on main as #{short}#{fixed}. Its worktree can go: wt remove #{done.branch}")
    done
  end

  defp tell(%Ticket{claimed_by: nil}, _text), do: :ok
  defp tell(%Ticket{claimed_by: pane}, text), do: Babylon.Inbox.send(pane, text)
end
