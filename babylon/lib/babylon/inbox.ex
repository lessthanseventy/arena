defmodule Babylon.Inbox do
  @moduledoc """
  babylon's word to a session. While the pane's Claude is mid-turn it is held, and arena's hook
  hands it over at the next tool call or as the turn would end (the `inbox` tool, by the pane);
  while it waits on its human a typed line would land in the open dialog, so it is held then too.
  A pane between turns is typed a short nudge to call `inbox`, once for what came in since the
  last, the messages left for it to take; one tmux could not type is tried again, a few times.
  """
  import Ecto.Query

  alias Babylon.Message
  alias Babylon.Repo

  @tries 4

  @doc "Keep `text` for `pane`, and type it in unless the pane is waiting."
  @spec send(String.t(), String.t()) :: Message.t()
  def send(pane, text) do
    message = Repo.insert!(%Message{pane: pane, text: text})
    deliver(pane)
    message
  end

  @doc "The messages `pane` has not read, oldest first, marked read now."
  @spec take(String.t()) :: [Message.t()]
  def take(pane) do
    unread = Repo.all(from m in Message, where: m.pane == ^pane and is_nil(m.read_at), order_by: m.id)
    Repo.update_all(from(m in Message, where: m.id in ^Enum.map(unread, & &1.id)), set: [read_at: now()])
    unread
  end

  @doc "Nudge every pane between turns with messages it has not been nudged for; the panes nudged."
  @spec deliver_held() :: [String.t()]
  def deliver_held do
    from(m in fresh(), distinct: true, select: m.pane)
    |> Repo.all()
    |> Enum.filter(&deliver/1)
  end

  defp fresh, do: from(m in Message, where: is_nil(m.read_at) and is_nil(m.nudged_at) and m.nudges < @tries)

  defp deliver(pane) do
    fresh = Repo.all(from m in fresh(), where: m.pane == ^pane)

    case {fresh, panes().state(pane)} do
      {[], _} -> false
      {_, state} when state in ["waiting", "working"] -> false
      _ -> nudge(pane, Enum.map(fresh, & &1.id))
    end
  end

  # once for what came in since the last nudge; one tmux will not type is tried again on the sweep
  defp nudge(pane, ids) do
    unread = Repo.aggregate(from(m in Message, where: m.pane == ^pane and is_nil(m.read_at)), :count)
    them = from(m in Message, where: m.id in ^ids)

    case panes().tell(
           pane,
           "babylon: #{unread} new #{if unread == 1, do: "message", else: "messages"} for you: call inbox"
         ) do
      :ok ->
        Repo.update_all(them, set: [nudged_at: now()])
        true

      {:error, _} ->
        Repo.update_all(them, inc: [nudges: 1])
        false
    end
  end

  defp panes, do: Application.get_env(:babylon, :panes, Babylon.Panes)

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
