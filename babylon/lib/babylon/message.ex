defmodule Babylon.Message do
  @moduledoc "What babylon has to tell a session's pane, kept until that session reads it."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "message" do
    field :pane, :string
    field :text, :string
    field :read_at, :utc_datetime
    field :nudged_at, :utc_datetime
    field :nudges, :integer, default: 0
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
