defmodule Babylon.Claims do
  @moduledoc """
  A session takes a ticket by claiming it for its tmux pane. The ticket moves to `doing` with a
  branch to work it on, and nobody else can take it while that pane runs Claude. A claim whose pane
  is gone lapses back to `todo`, labelled `lapsed`, keeping its branch for whoever picks it up.
  """
  import Ecto.Query

  alias Babylon.Repo
  alias Babylon.Ticket
  alias Babylon.Tickets

  @type panes :: MapSet.t(String.t()) | :unknown

  @doc """
  Claim ticket `id` for `pane`. `panes` is the set running Claude (`Babylon.Panes.claude/0`): a
  ticket held by one of them, or by anyone when tmux could not be asked, is refused. Claiming a
  ticket you hold already is not an error. `{:ok, ticket, :new | :resumed | :held}`, where `:new`
  means its branch was just named and `:resumed` that it already had one.
  """
  @spec claim(pos_integer(), String.t(), panes()) ::
          {:ok, Ticket.t(), :new | :resumed | :held} | {:error, String.t()}
  def claim(id, pane, panes) do
    Repo.transaction(fn ->
      ticket = Repo.one(from t in Ticket, where: t.id == ^id, lock: "FOR UPDATE")

      case claimable(ticket, id, pane, panes) do
        :ok -> take(ticket, pane)
        {:held, ticket} -> {ticket, :held}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {ticket, how}} -> {:ok, ticket, how}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Give ticket `id` back: `todo` again, its branch kept. Only the pane holding it can."
  @spec release(pos_integer(), String.t()) :: {:ok, Ticket.t()} | {:error, String.t()}
  def release(id, pane) do
    case Tickets.get(id) do
      nil -> {:error, "no ticket ##{id}"}
      %Ticket{claimed_by: ^pane} = ticket -> let_go(ticket, [])
      %Ticket{claimed_by: nil} -> {:error, "ticket ##{id} is not claimed"}
      %Ticket{claimed_by: other} -> {:error, "ticket ##{id} is claimed by pane #{other}, not this one"}
    end
  end

  @doc "Let go of every claim whose pane is not in `panes`, labelled `lapsed`. The ids let go."
  @spec lapse(panes()) :: [pos_integer()]
  def lapse(:unknown), do: []

  def lapse(panes) do
    held = Repo.all(from t in Ticket, where: not is_nil(t.claimed_by) and t.status != "done")

    for ticket <- held, not MapSet.member?(panes, ticket.claimed_by) do
      {:ok, _} = let_go(ticket, ["lapsed"])
      ticket.id
    end
  end

  defp claimable(nil, id, _pane, _panes), do: {:error, "no ticket ##{id}"}
  defp claimable(%Ticket{kind: "epic"}, id, _, _), do: {:error, "##{id} is an epic: claim one of its tickets"}
  defp claimable(%Ticket{status: "done"}, id, _, _), do: {:error, "ticket ##{id} is done"}
  defp claimable(%Ticket{claimed_by: pane} = ticket, _id, pane, _panes), do: {:held, ticket}

  defp claimable(%Ticket{claimed_by: other}, id, _pane, panes) when is_binary(other) do
    if panes == :unknown or MapSet.member?(panes, other),
      do: {:error, "ticket ##{id} is claimed by pane #{other}"},
      else: blocked(id)
  end

  defp claimable(%Ticket{}, id, _pane, _panes), do: blocked(id)

  defp blocked(id) do
    case Tickets.blockers(id) do
      [] -> :ok
      ids -> {:error, "ticket ##{id} waits on #{Enum.map_join(ids, ", ", &"##{&1}")}"}
    end
  end

  defp take(ticket, pane) do
    {branch, how} = if ticket.branch, do: {ticket.branch, :resumed}, else: {branch(ticket), :new}

    ticket
    |> Ecto.Changeset.change(
      status: "doing",
      claimed_by: pane,
      claimed_at: DateTime.truncate(DateTime.utc_now(), :second),
      branch: branch,
      labels: List.delete(ticket.labels, "lapsed")
    )
    |> Repo.update!()
    |> tap(&Tickets.refresh_epic(Tickets.epic_of(&1.id)))
    |> then(&{&1, how})
  end

  defp let_go(ticket, labels) do
    ticket
    |> Ecto.Changeset.change(
      status: "todo",
      claimed_by: nil,
      claimed_at: nil,
      labels: Enum.uniq(ticket.labels ++ labels)
    )
    |> Repo.update()
    |> tap(fn _ -> Tickets.refresh_epic(Tickets.epic_of(ticket.id)) end)
  end

  defp branch(%Ticket{id: id, title: title}) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.slice(0, 40)
      |> String.trim("-")

    "t#{id}-#{slug}"
  end
end
