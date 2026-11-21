defmodule Babylon.Tickets do
  @moduledoc "Filing, reading and changing tickets, and the links between them."
  import Ecto.Query

  alias Babylon.Repo
  alias Babylon.Ticket
  alias Babylon.TicketLink

  @type link_view :: %{kind: String.t(), direction: :in | :out, ticket_id: pos_integer()}

  @doc """
  File a ticket at the bottom of its repo's to-do list. With `epic_id` in `attrs` it is filed under
  that epic, and with `blocked_by` (ticket ids) it waits on those, all in one transaction, so a
  refused parent or blocker files nothing. `opts[:filed_by]` is the filing session's id.
  """
  @spec file(map(), keyword()) :: {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def file(attrs, opts \\ []) do
    {epic_id, attrs} = Map.pop(attrs, :epic_id)
    {blocked_by, attrs} = Map.pop(attrs, :blocked_by, [])
    attrs = Map.put_new_lazy(attrs, :sort, fn -> next_sort(attrs[:repo]) end)
    changeset = Ticket.file_changeset(attrs, opts[:filed_by])

    Repo.transaction(fn ->
      with {:ok, ticket} <- Repo.insert(changeset),
           {:ok, _} <- under(epic_id, ticket.id),
           :ok <- wait_on(blocked_by, ticket.id) do
        ticket
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc "A ticket by id, or nil."
  @spec get(pos_integer()) :: Ticket.t() | nil
  def get(id), do: Repo.get(Ticket, id)

  @doc """
  Tickets in board order, the top of a column first. `opts`: `:repo` narrows to one repository,
  `:status` to one status or a list of them, `:claimed_by` to the tickets a pane holds.
  """
  @spec list(keyword()) :: [Ticket.t()]
  def list(opts \\ []) do
    Enum.reduce(opts, from(t in Ticket, order_by: [asc: t.sort, asc: t.id]), fn
      {:repo, repo}, query -> where(query, [t], t.repo == ^repo)
      {:status, statuses}, query when is_list(statuses) -> where(query, [t], t.status in ^statuses)
      {:status, status}, query -> where(query, [t], t.status == ^status)
      {:claimed_by, pane}, query -> where(query, [t], t.claimed_by == ^pane)
    end)
    |> Repo.all()
  end

  @doc "Change a ticket's mutable fields; its epic's status follows."
  @spec update(Ticket.t(), map()) :: {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def update(%Ticket{} = ticket, attrs) do
    with {:ok, updated} <- ticket |> Ticket.update_changeset(attrs) |> Repo.update() do
      refresh_epic(epic_of(updated.id))
      {:ok, updated}
    end
  end

  @doc """
  Move a ticket one place up or down its column, past the next ticket in it (of `repo` alone when
  given, as a board narrowed to one shows it). At the column's end it stays.
  """
  @spec move(Ticket.t(), :up | :down, String.t() | nil) :: {:ok, Ticket.t()}
  def move(%Ticket{} = ticket, by, repo \\ nil) do
    column = list(status: ticket.status)
    shown = if repo, do: Enum.filter(column, &(&1.repo == repo)), else: column
    at = Enum.find_index(shown, &(&1.id == ticket.id))
    next = if by == :up, do: at - 1, else: at + 1

    case next >= 0 and Enum.at(shown, next) do
      %Ticket{} = past ->
        Repo.transaction(fn -> swap(column, ticket, past) end)
        {:ok, get(ticket.id)}

      _ ->
        {:ok, ticket}
    end
  end

  @doc "Delete a ticket and its links; its epic's status follows."
  @spec remove(Ticket.t()) :: {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def remove(%Ticket{} = ticket) do
    epic_id = epic_of(ticket.id)

    with {:ok, removed} <- Repo.delete(ticket) do
      refresh_epic(epic_id)
      {:ok, removed}
    end
  end

  @doc "Link `from_id` to `to_id`. Linking twice is not an error."
  @spec link(pos_integer(), pos_integer(), String.t()) :: {:ok, TicketLink.t()} | {:error, Ecto.Changeset.t()}
  def link(from_id, to_id, kind) do
    result =
      %{from_id: from_id, to_id: to_id, kind: kind}
      |> TicketLink.changeset()
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:from_id, :to_id, :kind])

    if kind == "parent" and match?({:ok, _}, result), do: refresh_epic(from_id)
    result
  end

  @doc "Remove a link. One that is not there is already removed."
  @spec unlink(pos_integer(), pos_integer(), String.t()) :: :ok
  def unlink(from_id, to_id, kind) do
    Repo.delete_all(from l in TicketLink, where: l.from_id == ^from_id and l.to_id == ^to_id and l.kind == ^kind)
    if kind == "parent", do: refresh_epic(from_id)
    :ok
  end

  @doc ~s(Every link touching a ticket, from both ends: `direction: :in, kind: "blocks"` is "blocked by".)
  @spec links_of(pos_integer()) :: [link_view()]
  def links_of(id) do
    Repo.all(
      from l in TicketLink,
        where: l.from_id == ^id or l.to_id == ^id,
        order_by: l.id,
        select: %{
          kind: l.kind,
          direction: fragment("CASE WHEN ? = ? THEN 'out' ELSE 'in' END", l.from_id, ^id),
          ticket_id: fragment("CASE WHEN ? = ? THEN ? ELSE ? END", l.from_id, ^id, l.to_id, l.from_id)
        }
    )
    |> Enum.map(&%{&1 | direction: String.to_existing_atom(&1.direction)})
  end

  @doc "The tickets blocking this one that are not done yet: a done blocker no longer blocks."
  @spec blockers(pos_integer()) :: [pos_integer()]
  def blockers(id) do
    Repo.all(
      from l in TicketLink,
        join: by in Ticket,
        on: by.id == l.from_id,
        where: l.to_id == ^id and l.kind == "blocks" and by.status != "done",
        order_by: l.from_id,
        select: l.from_id
    )
  end

  @doc "The epic a ticket is under, or nil."
  @spec epic_of(pos_integer()) :: pos_integer() | nil
  def epic_of(id), do: Repo.one(from l in TicketLink, where: l.to_id == ^id and l.kind == "parent", select: l.from_id)

  @doc "Set the epic `epic_id`'s status to the one its tickets give it. Nil is no epic."
  @spec refresh_epic(pos_integer() | nil) :: :ok
  def refresh_epic(nil), do: :ok

  def refresh_epic(epic_id) do
    epic = get(epic_id)

    statuses =
      Repo.all(
        from l in TicketLink,
          join: t in Ticket,
          on: t.id == l.to_id,
          where: l.from_id == ^epic_id and l.kind == "parent",
          select: t.status
      )

    case Ticket.epic_status(statuses) do
      same when same == epic.status -> :ok
      derived -> epic |> Ticket.derive_changeset(derived) |> Repo.update!()
    end

    :ok
  end

  # the column numbered afresh in its order, with the two traded
  defp swap(column, one, other) do
    sorts = column |> Enum.with_index(1) |> Map.new(fn {t, i} -> {t.id, i} end)
    sorts = %{sorts | one.id => sorts[other.id], other.id => sorts[one.id]}
    for t <- column, do: t |> Ecto.Changeset.change(sort: sorts[t.id]) |> Repo.update!()
  end

  # a new ticket joins the bottom of its repo's column: what was filed first is taken first
  defp next_sort(repo) do
    query = if repo, do: from(t in Ticket, where: t.repo == ^repo), else: from(t in Ticket, where: is_nil(t.repo))
    (Repo.one(from t in query, select: max(t.sort)) || 0) + 1
  end

  defp under(nil, _id), do: {:ok, nil}
  defp under(epic_id, id), do: link(epic_id, id, "parent")

  defp wait_on(blockers, id) do
    Enum.reduce_while(blockers, :ok, fn by, :ok ->
      case link(by, id, "blocks") do
        {:ok, _} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end
end
