defmodule Babylon.Inbox do
  @moduledoc """
  babylon's word to a session: kept per pane until the session reads it with the `inbox` tool.
  What is typed into the pane is only a nudge to read it, so a line lost to an open dialog loses
  nothing; an unread message is nudged again, a few times, while its pane is not waiting on its
  human.
  """
  import Ecto.Query

  alias Babylon.Message
  alias Babylon.Panes
  alias Babylon.Repo

  @renudge_after 60
  @nudges 4

  @doc "Keep `text` for `pane`, and nudge it."
  @spec send(String.t(), String.t()) :: Message.t()
  def send(pane, text) do
    message = Repo.insert!(%Message{pane: pane, text: text})
    nudge(pane)
    message
  end

  @doc "The messages `pane` has not read, oldest first, marked read now."
  @spec take(String.t()) :: [Message.t()]
  def take(pane) do
    unread = Repo.all(from m in Message, where: m.pane == ^pane and is_nil(m.read_at), order_by: m.id)
    Repo.update_all(from(m in Message, where: m.id in ^Enum.map(unread, & &1.id)), set: [read_at: now()])
    unread
  end

  @doc "Nudge every pane with a message still unread long after its last nudge, up to a few times."
  @spec renudge() :: [String.t()]
  def renudge do
    before = DateTime.add(now(), -@renudge_after, :second)

    from(m in Message,
      where: is_nil(m.read_at) and m.nudges < @nudges and (is_nil(m.nudged_at) or m.nudged_at < ^before),
      distinct: true,
      select: m.pane
    )
    |> Repo.all()
    |> Enum.filter(&nudge/1)
  end

  # held while the pane's Claude waits on its human: a line typed into an open dialog is lost
  defp nudge(pane) do
    unread = from(m in Message, where: m.pane == ^pane and is_nil(m.read_at))

    case {Panes.state(pane), Repo.aggregate(unread, :count)} do
      {_, 0} ->
        false

      {"waiting", _} ->
        false

      {_, n} ->
        Panes.tell(pane, "babylon: #{n} new for this session: call babylon's inbox tool to read them.")
        Repo.update_all(unread, set: [nudged_at: now()], inc: [nudges: 1])
        true
    end
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
