defmodule Babylon.Ticket do
  @moduledoc """
  A piece of work any session can file and any session can pick up. `repo` names the repository it
  is for; nil is work not tied to one. An epic holds tickets through `parent` links
  (`Babylon.TicketLink`), is never worked itself, and its status is derived from its tickets'.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(backlog todo doing done)
  @priorities ~w(low med high)
  @kinds ~w(ticket epic)
  @mutable [:repo, :title, :body, :status, :priority, :labels, :sort]

  schema "ticket" do
    field :repo, :string
    field :title, :string
    field :body, :string, default: ""
    field :kind, :string, default: "ticket"
    field :status, :string, default: "backlog"
    field :priority, :string, default: "med"
    field :labels, {:array, :string}, default: []
    field :filed_by, :string
    field :sort, :integer, default: 0
    field :closed_at, :utc_datetime
    field :claimed_by, :string
    field :claimed_at, :utc_datetime
    field :branch, :string
    timestamps(type: :utc_datetime)
  end

  @doc "A new ticket. `filed_by` is the filing session's id, taken apart from `attrs` so a caller cannot claim another's."
  @spec file_changeset(map(), String.t() | nil) :: Ecto.Changeset.t()
  def file_changeset(attrs, filed_by) do
    %__MODULE__{filed_by: filed_by}
    |> cast(attrs, [:kind | @mutable])
    |> validate_required([:title])
    |> validate_sets()
    |> stamp_closed()
  end

  @doc "A change to a ticket's mutable fields. An epic's status is derived, so it is not cast."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = ticket, attrs) do
    fields = if ticket.kind == "epic", do: List.delete(@mutable, :status), else: @mutable

    ticket
    |> cast(attrs, fields)
    |> validate_required([:title])
    |> validate_sets()
    |> stamp_closed()
  end

  @doc "An epic's status set to the one derived from its tickets'."
  @spec derive_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def derive_changeset(%__MODULE__{kind: "epic"} = epic, status), do: epic |> change(status: status) |> stamp_closed()

  @doc "An epic's status from its tickets': `done` when all are, `doing` once one has started, else `backlog`."
  @spec epic_status([String.t()]) :: String.t()
  def epic_status([]), do: "backlog"

  def epic_status(statuses) do
    cond do
      Enum.all?(statuses, &(&1 == "done")) -> "done"
      Enum.any?(statuses, &(&1 in ~w(doing done))) -> "doing"
      true -> "backlog"
    end
  end

  defp validate_sets(changeset) do
    changeset
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_inclusion(:kind, @kinds)
  end

  # closed_at follows status, so "closed" and "when" cannot disagree
  defp stamp_closed(changeset) do
    case {get_field(changeset, :status), get_field(changeset, :closed_at)} do
      {"done", nil} -> put_change(changeset, :closed_at, DateTime.truncate(DateTime.utc_now(), :second))
      {"done", _} -> changeset
      {_, nil} -> changeset
      {_, _} -> put_change(changeset, :closed_at, nil)
    end
  end
end
