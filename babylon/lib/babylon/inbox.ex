defmodule Babylon.Inbox do
  @moduledoc """
  babylon's word to a session, typed into its pane whole and marked read once tmux has typed it.
  While the pane's Claude waits on its human a typed line would land in the open dialog and be
  lost, so it is held then, and typed on a later sweep; one tmux could not type is tried again,
  a few times. The `inbox` tool reads what is still held.
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

  @doc "Type in what is held for every pane, those still waiting on their human left; the panes typed into."
  @spec deliver_held() :: [String.t()]
  def deliver_held do
    from(m in Message, where: is_nil(m.read_at) and m.nudges < @tries, distinct: true, select: m.pane)
    |> Repo.all()
    |> Enum.filter(&(deliver(&1) > 0))
  end

  # oldest first, stopping at the first tmux will not type, which keeps its turn
  defp deliver(pane) do
    held =
      Repo.all(from m in Message, where: m.pane == ^pane and is_nil(m.read_at) and m.nudges < @tries, order_by: m.id)

    if panes().state(pane) == "waiting", do: 0, else: Enum.reduce_while(held, 0, &type_in(pane, &1, &2))
  end

  defp type_in(pane, message, typed) do
    case panes().tell(pane, "babylon: " <> message.text) do
      :ok ->
        message |> Ecto.Changeset.change(read_at: now()) |> Repo.update!()
        {:cont, typed + 1}

      {:error, _} ->
        message |> Ecto.Changeset.change(nudged_at: now(), nudges: message.nudges + 1) |> Repo.update!()
        {:halt, typed}
    end
  end

  defp panes, do: Application.get_env(:babylon, :panes, Babylon.Panes)

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
