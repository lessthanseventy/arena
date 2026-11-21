defmodule Babylon.Orchestrator do
  @moduledoc """
  The standing Claude over every session and the board, in tmux's `orchestrator` session
  (`babylon orchestrator` starts it).
  """

  @doc "Tell the orchestrator `text`, through its inbox; nothing when it is not running."
  @spec tell(String.t()) :: :ok
  def tell(text) do
    session = Application.get_env(:babylon, :orchestrator_session, "orchestrator")
    panes = Application.get_env(:babylon, :panes, Babylon.Panes)
    with pane when is_binary(pane) <- panes.claude_in(session), do: Babylon.Inbox.send(pane, text)
    :ok
  end
end
