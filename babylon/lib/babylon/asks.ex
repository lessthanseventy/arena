defmodule Babylon.Asks do
  @moduledoc "Asking the human a decision, and handing the answer back to the session that asked."
  import Ecto.Query

  alias Babylon.Ask
  alias Babylon.Panes
  alias Babylon.Repo
  alias Babylon.Ticket

  @doc "Ask, from `pane`, the question in `attrs` about its ticket."
  @spec ask(map(), String.t()) :: {:ok, Ask.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def ask(attrs, pane) do
    case Repo.get(Ticket, attrs[:ticket_id]) do
      nil -> {:error, "no ticket ##{attrs[:ticket_id]}"}
      _ -> attrs |> Ask.changeset(pane) |> Repo.insert()
    end
  end

  @doc """
  Answer ask `id` with its option number `choice` (from 1), and type the answer into the pane that
  asked. An ask answered already is refused.
  """
  @spec answer(pos_integer(), pos_integer()) :: {:ok, Ask.t()} | {:error, String.t()}
  def answer(id, choice) do
    case Repo.get(Ask, id) do
      nil ->
        {:error, "no ask ##{id}"}

      %Ask{answered_at: at} when at != nil ->
        {:error, "ask ##{id} is answered already"}

      %Ask{options: options} when choice not in 1..length(options)//1 ->
        {:error, "ask ##{id} has options 1 to #{length(options)}"}

      ask ->
        picked = Enum.at(ask.options, choice - 1)
        now = DateTime.truncate(DateTime.utc_now(), :second)
        answered = ask |> Ecto.Changeset.change(answer: picked, answered_at: now) |> Repo.update!()
        Panes.tell(ask.pane, ~s(babylon: you asked about ##{ask.ticket_id}, "#{ask.question}" The answer: #{picked}))
        {:ok, answered}
    end
  end

  @doc "The open asks, oldest first."
  @spec open() :: [Ask.t()]
  def open, do: Repo.all(from a in Ask, where: is_nil(a.answered_at), order_by: [asc: a.id])
end
