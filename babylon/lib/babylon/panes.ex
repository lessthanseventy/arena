defmodule Babylon.Panes do
  @moduledoc """
  Which tmux panes are running Claude. A claim lives as long as its pane does, so a session that
  waits an hour on an answer keeps its ticket and one whose pane is gone lets it go.
  """

  @doc "Where every tmux pane is (its current path), or `:unknown` when tmux cannot say."
  @spec paths() :: [String.t()] | :unknown
  def paths do
    case System.cmd("tmux", ["list-panes", "-a", "-F", "\#{pane_current_path}"], stderr_to_stdout: true) do
      {out, 0} -> String.split(out, "\n", trim: true)
      _ -> :unknown
    end
  rescue
    ErlangError -> :unknown
  end

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

  @doc "The pane running Claude in tmux session `session`, or nil when there is none."
  @spec claude_in(String.t()) :: String.t() | nil
  def claude_in(session) do
    case System.cmd("tmux", ["list-panes", "-t", "=" <> session, "-F", "\#{pane_id} \#{pane_current_command}"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> Enum.find_value(String.split(out, "\n", trim: true), &claude_pane/1)
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  @doc "The name babylon last typed `/rename` for into `pane`; empty where none."
  @spec named(String.t()) :: String.t()
  def named(pane) do
    case System.cmd("tmux", ["show", "-pqv", "-t", pane, "@babylon_named"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> ""
    end
  rescue
    ErlangError -> ""
  end

  @doc "Keep on `pane` that babylon typed `/rename name` into it."
  @spec mark_named(String.t(), String.t()) :: :ok
  def mark_named(pane, name) do
    System.cmd("tmux", ["set", "-p", "-t", pane, "@babylon_named", name], stderr_to_stdout: true)
    # the rail's title, which arena's hook would read only once the turn ends
    System.cmd("tmux", ["set", "-p", "-t", pane, "@arena_claude_title", name], stderr_to_stdout: true)
    :ok
  rescue
    ErlangError -> :ok
  end

  @doc "What arena's hook last read as `pane`'s session title; empty where it has none."
  @spec title(String.t()) :: String.t()
  def title(pane) do
    case System.cmd("tmux", ["show", "-pqv", "-t", pane, "@arena_claude_title"], stderr_to_stdout: true) do
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
  @spec tell(String.t(), String.t()) :: :ok | :typing | {:error, String.t()}
  def tell(pane, text) do
    line = String.replace(text, ~r/\s*\n\s*/, " ")

    with :empty <- box(pane),
         {_, 0} <- System.cmd("tmux", ["send-keys", "-t", pane, "-l", line], stderr_to_stdout: true),
         {_, 0} <- System.cmd("tmux", ["send-keys", "-t", pane, "Enter"], stderr_to_stdout: true) do
      submitted(pane, line, 4)
    else
      :typing -> :typing
      {out, _} -> {:error, "tmux would not type into #{pane}: #{String.trim(out)}"}
    end
  rescue
    ErlangError -> {:error, "there is no tmux to type into #{pane}"}
  end

  @doc """
  Whether the input box of the Claude drawn in `screen` (with its escapes, as `capture-pane -e`
  gives it) holds text typed there: the plain text after its last `❯`, a suggestion drawn dim or
  grey not counted.
  """
  @spec typed?(String.t()) :: boolean()
  def typed?(screen) do
    case screen |> String.split("\n") |> Enum.filter(&String.contains?(&1, "❯")) |> List.last() do
      nil ->
        false

      line ->
        [_, after_prompt] = String.split(line, "❯", parts: 2)

        ~r/\e\[([0-9;]*)m/
        |> Regex.split(after_prompt, include_captures: true)
        |> Enum.reduce({false, ""}, &plain/2)
        |> elem(1)
        |> String.replace(" ", " ")
        |> String.trim()
        |> Kernel.!=("")
    end
  end

  @doc """
  Whether `line` is still in the input box of the Claude drawn in `screen`: its last `❯` prompt
  line and those under it, up to the rule closing the box.
  """
  @spec pending?(String.t(), String.t()) :: boolean()
  def pending?(screen, line) do
    lines = String.split(screen, "\n")
    prompts = for {l, i} <- Enum.with_index(lines), String.starts_with?(String.trim_leading(l), "❯"), do: i

    case List.last(prompts) do
      nil ->
        false

      at ->
        box =
          lines
          |> Enum.drop(at)
          |> Enum.take_while(&(not String.starts_with?(String.trim_leading(&1), "─")))
          |> Enum.map_join(" ", &String.trim/1)

        String.contains?(box, String.slice(line, 0, 30))
    end
  end

  # a burst of keys can be taken as a paste, its Enter a newline in the box: Enter again until the
  # text has left it
  defp submitted(_pane, _line, 0), do: :ok

  defp submitted(pane, line, tries) do
    Process.sleep(400)

    with {screen, 0} <- System.cmd("tmux", ["capture-pane", "-p", "-t", pane], stderr_to_stdout: true),
         true <- pending?(screen, line) do
      System.cmd("tmux", ["send-keys", "-t", pane, "Enter"], stderr_to_stdout: true)
      submitted(pane, line, tries - 1)
    else
      _ -> :ok
    end
  end

  defp claude_pane(line) do
    case String.split(line, " ", parts: 2) do
      [id, "claude"] -> id
      _ -> nil
    end
  end

  # its human may be typing in it: nothing is typed over that
  defp box(pane) do
    case System.cmd("tmux", ["capture-pane", "-ep", "-t", pane], stderr_to_stdout: true) do
      {screen, 0} -> if typed?(screen), do: :typing, else: :empty
      _ -> :empty
    end
  end

  defp plain("\e[" <> sgr, {_faint, kept}) do
    params = sgr |> String.trim_trailing("m") |> String.split(";")
    {faint?(params), kept}
  end

  defp plain(text, {true, kept}), do: {true, kept <> String.duplicate(" ", String.length(text))}
  defp plain(text, {false, kept}), do: {false, kept <> text}

  defp faint?(["38", "5", n | _]), do: String.to_integer(n) == 8 or String.to_integer(n) in 232..250
  defp faint?(params), do: "2" in params or "90" in params
end
