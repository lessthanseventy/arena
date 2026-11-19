defmodule Babylon.MCP.Tools.FileTicket do
  @moduledoc """
  File a ticket: work you or another session could pick up later. It joins the bottom of its
  repo's backlog. Give `repo` (the repository's directory name) unless it is tied to none.
  """
  use Babylon.MCP.Tool

  alias Babylon.Tickets

  schema do
    field :title, :string, required: true, description: "What the work is, in one line"
    field :body, :string, description: "What someone picking it up needs to know"
    field :repo, :string, description: "The repository it is for, by its directory name"
    field :priority, :enum, values: ~w(low med high), description: "med when left out"
    field :labels, {:list, :string}
    field :kind, :enum, values: ~w(ticket epic), description: "an epic holds tickets and is never worked itself"
    field :epic_id, :integer, description: "File it under this epic"
    field :blocked_by, {:list, :integer}, description: "Ids of the tickets it waits on"
  end

  @impl true
  def execute(params, frame), do: reply(frame, Tickets.file(given(params)), &render/1)
end

defmodule Babylon.MCP.Tools.ListTickets do
  @moduledoc "Tickets in board order, the top of each column first. Narrow by repo and status."
  use Babylon.MCP.Tool

  alias Babylon.Tickets

  schema do
    field :repo, :string, description: "Only this repository's"
    field :status, {:list, {:enum, ~w(backlog todo doing done)}}, description: "Only these statuses"
  end

  @impl true
  def execute(params, frame) do
    ok(frame, params |> given() |> Keyword.new() |> Tickets.list() |> Enum.map(&render/1))
  end
end

defmodule Babylon.MCP.Tools.GetTicket do
  @moduledoc "One ticket, with its links, the tickets still blocking it and its epic."
  use Babylon.MCP.Tool

  alias Babylon.Tickets

  schema do
    field :id, :integer, required: true
  end

  @impl true
  def execute(%{id: id}, frame) do
    with_ticket(frame, id, fn ticket ->
      ok(
        frame,
        Map.merge(render(ticket), %{
          links: Tickets.links_of(id),
          blocked_by: Tickets.blockers(id),
          epic_id: Tickets.epic_of(id)
        })
      )
    end)
  end
end

defmodule Babylon.MCP.Tools.UpdateTicket do
  @moduledoc "Change a ticket. Fields left out stay as they are. An epic's status follows its tickets'."
  use Babylon.MCP.Tool

  alias Babylon.Tickets

  schema do
    field :id, :integer, required: true
    field :title, :string
    field :body, :string
    field :repo, :string
    field :status, :enum, values: ~w(backlog todo doing done)
    field :priority, :enum, values: ~w(low med high)
    field :labels, {:list, :string}
  end

  @impl true
  def execute(%{id: id} = params, frame) do
    changes = params |> given() |> Map.delete(:id)
    with_ticket(frame, id, fn ticket -> reply(frame, Tickets.update(ticket, changes), &render/1) end)
  end
end

defmodule Babylon.MCP.Tools.LinkTickets do
  @moduledoc """
  Link two tickets: `from` blocks `to`, relates to it, duplicates it, or is its epic (`parent`).
  Linking twice is not an error.
  """
  use Babylon.MCP.Tool

  alias Babylon.Tickets

  schema do
    field :from, :integer, required: true
    field :to, :integer, required: true
    field :kind, :enum, values: ~w(blocks relates duplicates parent), required: true
  end

  @impl true
  def execute(%{from: from, to: to, kind: kind}, frame) do
    reply(frame, Tickets.link(from, to, kind), fn _ -> Tickets.links_of(to) end)
  end
end

defmodule Babylon.MCP.Tools.UnlinkTickets do
  @moduledoc "Remove a link between two tickets. One that is not there is already removed."
  use Babylon.MCP.Tool

  alias Babylon.Tickets

  schema do
    field :from, :integer, required: true
    field :to, :integer, required: true
    field :kind, :enum, values: ~w(blocks relates duplicates parent), required: true
  end

  @impl true
  def execute(%{from: from, to: to, kind: kind}, frame) do
    :ok = Tickets.unlink(from, to, kind)
    ok(frame, Tickets.links_of(to))
  end
end
