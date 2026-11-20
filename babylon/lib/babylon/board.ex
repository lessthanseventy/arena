defmodule Babylon.Board do
  @moduledoc """
  The board arena draws, kept as a JSON file: every open ticket, and those done in the last day.
  It is built afresh each second and written only when it differs, so a change made by any path
  shows within a second. Written to a file beside it and renamed, so a reader never sees half.
  """
  use GenServer

  import Ecto.Query

  alias Babylon.Repo
  alias Babylon.Ticket
  alias Babylon.TicketLink

  @every to_timeout(second: 1)

  @doc "Keep the board at `path`."
  @spec start_link(Path.t()) :: GenServer.on_start()
  def start_link(path), do: GenServer.start_link(__MODULE__, path, name: __MODULE__)

  @doc """
  The board now, each card with the open tickets blocking it and the epic it is under, in board
  order: the top of a column first.
  """
  @spec build() :: %{tickets: [map()]}
  def build do
    since = DateTime.add(DateTime.utc_now(), -1, :day)

    tickets =
      Repo.all(
        from t in Ticket,
          where: t.status != "done" or t.closed_at > ^since,
          order_by: [asc: t.sort, asc: t.id]
      )

    links =
      Repo.all(
        from l in TicketLink,
          join: by in Ticket,
          on: by.id == l.from_id,
          where: (l.kind == "blocks" and by.status != "done") or l.kind == "parent",
          order_by: l.from_id,
          select: {l.kind, l.from_id, l.to_id}
      )

    blockers = Enum.group_by(for({"blocks", from, to} <- links, do: {to, from}), &elem(&1, 0), &elem(&1, 1))
    epics = Map.new(for {"parent", from, to} <- links, do: {to, from})

    %{tickets: Enum.map(tickets, &card(&1, Map.get(blockers, &1.id, []), epics[&1.id]))}
  end

  @impl true
  def init(path), do: {:ok, {path, nil}, {:continue, :write}}

  @impl true
  def handle_continue(:write, state), do: write(state)

  @impl true
  def handle_info(:write, state), do: write(state)

  defp write({path, last}) do
    Process.send_after(self(), :write, @every)

    case JSON.encode!(build()) do
      ^last ->
        {:noreply, {path, last}}

      board ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path <> ".new", board)
        File.rename!(path <> ".new", path)
        {:noreply, {path, board}}
    end
  end

  defp card(%Ticket{} = t, blocked_by, epic_id) do
    t
    |> Map.take(~w(id repo title kind status priority labels claimed_by branch)a)
    |> Map.merge(%{blocked_by: blocked_by, epic_id: epic_id})
  end
end
