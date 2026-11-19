defmodule Babylon.MCP.Tool do
  @moduledoc "What every tool shares: `use Babylon.MCP.Tool` makes an anubis tool and brings in the replies."
  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Babylon.Ticket
  alias Babylon.Tickets

  @type reply :: {:reply, Response.t(), Frame.t()}

  defmacro __using__(_opts) do
    quote do
      use Anubis.Server.Component, type: :tool

      import Babylon.MCP.Tool, only: [ok: 2, fail: 2, reply: 3, given: 1, render: 1, with_ticket: 3]
    end
  end

  @doc "A reply carrying `payload` as JSON."
  @spec ok(Frame.t(), term()) :: reply()
  def ok(frame, payload), do: {:reply, Response.json(Response.tool(), payload), frame}

  @doc "A refusal the caller reads as one sentence."
  @spec fail(Frame.t(), String.t()) :: reply()
  def fail(frame, message), do: {:reply, Response.error(Response.tool(), message), frame}

  @doc "A reply from a context's result: the row rendered, or the changeset's errors as one sentence."
  @spec reply(Frame.t(), {:ok, term()} | {:error, Ecto.Changeset.t()}, (term() -> term())) :: reply()
  def reply(frame, {:ok, row}, render), do: ok(frame, render.(row))
  def reply(frame, {:error, %Ecto.Changeset{} = changeset}, _render), do: fail(frame, sentence(changeset))

  @doc "The params a caller gave: those left out arrive as nil and are dropped."
  @spec given(map()) :: map()
  def given(params), do: params |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

  @doc "Run `fun` on the ticket `id`, or refuse when there is none."
  @spec with_ticket(Frame.t(), pos_integer(), (Ticket.t() -> reply())) :: reply()
  def with_ticket(frame, id, fun) do
    case Tickets.get(id) do
      nil -> fail(frame, "no ticket ##{id}")
      ticket -> fun.(ticket)
    end
  end

  @doc "A ticket as a tool answers it."
  @spec render(Ticket.t()) :: map()
  def render(%Ticket{} = t) do
    Map.take(t, ~w(id repo title body kind status priority labels filed_by sort closed_at inserted_at updated_at)a)
  end

  defp sentence(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc -> String.replace(acc, "%{#{key}}", to_string(value)) end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end
