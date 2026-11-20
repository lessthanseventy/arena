defmodule Babylon.Panes do
  @moduledoc """
  Which tmux panes are running Claude. A claim lives as long as its pane does, so a session that
  waits an hour on an answer keeps its ticket and one whose pane is gone lets it go.
  """

  @doc "The ids of the panes running Claude, or `:unknown` when tmux cannot be asked."
  @spec claude() :: MapSet.t(String.t()) | :unknown
  def claude do
    case System.cmd("tmux", ["list-panes", "-a", "-F", "\#{pane_id} \#{pane_current_command}"], stderr_to_stdout: true) do
      {out, 0} ->
        for line <- String.split(out, "\n", trim: true),
            [id, "claude"] <- [String.split(line, " ", parts: 2)],
            into: MapSet.new(),
            do: id

      _ ->
        :unknown
    end
  rescue
    ErlangError -> :unknown
  end

  @doc """
  Type `text` into `pane` as one line and submit it, as if its human had: an idle Claude takes it
  as its next turn, a busy one queues it.
  """
  @spec tell(String.t(), String.t()) :: :ok
  def tell(pane, text) do
    line = String.replace(text, ~r/\s*\n\s*/, " ")
    _ = System.cmd("tmux", ["send-keys", "-t", pane, "-l", line], stderr_to_stdout: true)
    _ = System.cmd("tmux", ["send-keys", "-t", pane, "Enter"], stderr_to_stdout: true)
    :ok
  rescue
    ErlangError -> :ok
  end
end
