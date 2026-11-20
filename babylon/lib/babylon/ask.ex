defmodule Babylon.Ask do
  @moduledoc """
  A decision a session needs from its human, about a ticket: a question and the options to pick
  from. It is open until answered, and the answer goes back to the asking pane.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "ask" do
    belongs_to :ticket, Babylon.Ticket
    field :pane, :string
    field :question, :string
    field :options, {:array, :string}
    field :answer, :string
    field :answered_at, :utc_datetime
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "A new ask from `pane`: a question with two to nine options."
  @spec changeset(map(), String.t()) :: Ecto.Changeset.t()
  def changeset(attrs, pane) do
    %__MODULE__{pane: pane}
    |> cast(attrs, [:ticket_id, :question, :options])
    |> validate_required([:ticket_id, :question, :options])
    |> validate_length(:options, min: 2, max: 9)
    |> foreign_key_constraint(:ticket_id)
  end
end
