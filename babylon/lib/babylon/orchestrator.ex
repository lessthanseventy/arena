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

  defp pane do
    session = Application.get_env(:babylon, :orchestrator_session, "orchestrator")

    case System.cmd("tmux", ["list-panes", "-t", "=" <> session, "-F", "\#{pane_id} \#{pane_current_command}"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> Enum.find_value(String.split(out, "\n", trim: true), &claude_pane/1)
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  defp claude_pane(line) do
    case String.split(line, " ", parts: 2) do
      [id, "claude"] -> id
      _ -> nil
    end
  end
end
