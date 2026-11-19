defmodule Babylon.TicketLink do
  @moduledoc """
  A tie between two tickets: `blocks`, `relates`, `duplicates` or `parent`. Stored one way and read
  from both ends: "A is blocked by B" is the row `B blocks A`, so the two directions cannot
  disagree. A `parent` runs from an epic to a ticket, and a ticket has one.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Babylon.Repo
  alias Babylon.Ticket

  @type t :: %__MODULE__{}

  @kinds ~w(blocks relates duplicates parent)

  schema "ticket_link" do
    field :kind, :string
    belongs_to :from, Ticket
    belongs_to :to, Ticket
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The kinds a link may have."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "A link from `from_id` to `to_id`. Refuses a self-link, an unknown kind and a parent that is not an epic over a ticket."
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:from_id, :to_id, :kind])
    |> validate_required([:from_id, :to_id, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_not_self()
    |> validate_parent()
    |> foreign_key_constraint(:from_id)
    |> foreign_key_constraint(:to_id)
    |> check_constraint(:to_id, name: :not_self, message: "a ticket cannot link to itself")
    |> unique_constraint(:to_id, name: :ticket_link_one_parent, message: "already has a parent")
  end

  defp validate_not_self(changeset) do
    if get_field(changeset, :from_id) == get_field(changeset, :to_id),
      do: add_error(changeset, :to_id, "a ticket cannot link to itself"),
      else: changeset
  end

  defp validate_parent(changeset) do
    with "parent" <- get_field(changeset, :kind),
         true <- changeset.valid?,
         %Ticket{kind: from_kind} <- Repo.get(Ticket, get_field(changeset, :from_id)),
         %Ticket{kind: to_kind} <- Repo.get(Ticket, get_field(changeset, :to_id)) do
      parent_pairing(changeset, from_kind, to_kind)
    else
      _ -> changeset
    end
  end

  defp parent_pairing(changeset, "epic", "ticket"), do: changeset
  defp parent_pairing(changeset, "ticket", _), do: add_error(changeset, :from_id, "only an epic can be a parent")
  defp parent_pairing(changeset, "epic", "epic"), do: add_error(changeset, :to_id, "an epic cannot hold an epic")
end
