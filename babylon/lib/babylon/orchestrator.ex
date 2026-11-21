defmodule Babylon.Orchestrator do
  @moduledoc """
  The standing Claude over every session and the board, in tmux's `orchestrator` session
  (`babylon orchestrator` starts it).
  """

  @doc "Tell the orchestrator `text`, through its inbox; nothing when it is not running."
  @spec tell(String.t()) :: :ok
  def tell(text) do
    with pane when is_binary(pane) <- pane(), do: Babylon.Inbox.send(pane, text)
    :ok
  end

  @doc "The orchestrator's pane, or nil when it is not running."
  @spec pane() :: String.t() | nil
  def pane do
    session = Application.get_env(:babylon, :orchestrator_session, "orchestrator")
    Application.get_env(:babylon, :panes, Babylon.Panes).claude_in(session)
  end
end
