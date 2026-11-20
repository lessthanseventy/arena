defmodule Babylon.Asks do
  @moduledoc "Asking the human a decision, and handing the answer back to the session that asked."
  import Ecto.Query

  alias Babylon.Ask
  alias Babylon.Panes
  alias Babylon.Repo
  alias Babylon.Ticket

  @doc "Ask, from `pane`, the question in `attrs` about its ticket: one open ask a ticket."
  @spec ask(map(), String.t()) :: {:ok, Ask.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def ask(attrs, pane) do
    open = Repo.one(from a in Ask, where: a.ticket_id == ^attrs[:ticket_id] and is_nil(a.answered_at), limit: 1)

    case {Repo.get(Ticket, attrs[:ticket_id]), open} do
      {nil, _} -> {:error, "no ticket ##{attrs[:ticket_id]}"}
      {_, %Ask{id: id}} -> {:error, "##{attrs[:ticket_id]} has ask ##{id} open: wait for its answer"}
      _ -> attrs |> Ask.changeset(pane) |> Repo.insert()
    end
  end

  @doc """
  Answer ask `id` with its option number `choice` (from 1), and type the answer into the pane that
  asked. An ask answered already is refused; so is one whose pane no longer runs Claude (by
  `live`, the panes that do), which is closed unanswered, as no one is left to tell.
  """
  @spec answer(pos_integer(), pos_integer(), MapSet.t(String.t()) | :unknown) ::
          {:ok, Ask.t()} | {:error, String.t()}
  def answer(id, choice, live \\ Panes.claude()) do
    case Repo.get(Ask, id) do
      nil ->
        {:error, "no ask ##{id}"}

      %Ask{answered_at: at} when at != nil ->
        {:error, "ask ##{id} is answered already"}

      %Ask{options: options} when choice not in 1..length(options)//1 ->
        {:error, "ask ##{id} has options 1 to #{length(options)}"}

      ask ->
        if live == :unknown or MapSet.member?(live, ask.pane), do: give(ask, choice), else: close(ask)
    end
  end

  @doc "The open asks, oldest first."
  @spec open() :: [Ask.t()]
  def open, do: Repo.all(from a in Ask, where: is_nil(a.answered_at), order_by: [asc: a.id])

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp close(ask) do
    Repo.update!(Ecto.Changeset.change(ask, answered_at: now()))
    {:error, "the session that asked ##{ask.id} is gone (pane #{ask.pane}): closed unanswered"}
  end

  defp give(ask, choice) do
    picked = Enum.at(ask.options, choice - 1)
    answered = ask |> Ecto.Changeset.change(answer: picked, answered_at: now()) |> Repo.update!()
    Panes.tell(ask.pane, ~s(babylon: you asked about ##{ask.ticket_id}, "#{ask.question}" The answer: #{picked}))
    {:ok, answered}
  end
end
