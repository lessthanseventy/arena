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
  What `pane`'s Claude is doing, as arena's hook keeps it on the pane: `working`, `waiting` (on its
  human: a permission or a question is open), `done`, or `""` when unknown.
  """
  @spec state(String.t()) :: String.t()
  def state(pane) do
    case System.cmd("tmux", ["show", "-pqv", "-t", pane, "@arena_claude"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> ""
    end
  rescue
    ErlangError -> ""
  end

  @doc """
  Type `text` into `pane` as one line and submit it, as if its human had: an idle Claude takes it
  as its next turn, a busy one queues it.
  """
  @spec tell(String.t(), String.t()) :: :ok | {:error, String.t()}
  def tell(pane, text) do
    line = String.replace(text, ~r/\s*\n\s*/, " ")

    with {_, 0} <- System.cmd("tmux", ["send-keys", "-t", pane, "-l", line], stderr_to_stdout: true),
         {_, 0} <- System.cmd("tmux", ["send-keys", "-t", pane, "Enter"], stderr_to_stdout: true) do
      :ok
    else
      {out, _} -> {:error, "tmux would not type into #{pane}: #{String.trim(out)}"}
    end
  rescue
    ErlangError -> {:error, "there is no tmux to type into #{pane}"}
  end
end
