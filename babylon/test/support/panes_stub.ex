defmodule Babylon.PanesStub do
  @moduledoc """
  tmux's panes in tests: a pane in `:live_panes` is typed into (said to the process in
  `:told_to`), one in `:typing_panes` has its human typing in its box, one in `:waiting_panes`
  waits on its human, one in `:working_panes` is mid-turn,
  and any other cannot be typed into. A pane in neither is done with its turn.
  """

  @doc "What the pane's Claude is doing."
  @spec state(String.t()) :: String.t()
  def state(pane) do
    cond do
      pane in Application.get_env(:babylon, :waiting_panes, []) -> "waiting"
      pane in Application.get_env(:babylon, :working_panes, []) -> "working"
      true -> "done"
    end
  end

  @doc "The pane named for `session` in `:claude_in`."
  @spec claude_in(String.t()) :: String.t() | nil
  def claude_in(session), do: Application.get_env(:babylon, :claude_in, %{})[session]

  @doc "The name last typed into the pane, from `:named`."
  @spec named(String.t()) :: String.t()
  def named(pane), do: Map.get(Application.get_env(:babylon, :named, %{}), pane, "")

  @doc "Keep the name typed into the pane in `:named`."
  @spec mark_named(String.t(), String.t()) :: :ok
  def mark_named(pane, name) do
    Application.put_env(:babylon, :named, Map.put(Application.get_env(:babylon, :named, %{}), pane, name))
  end

  @doc "The pane's title, from `:titles`."
  @spec title(String.t()) :: String.t()
  def title(pane), do: Map.get(Application.get_env(:babylon, :titles, %{}), pane, "")

  @doc "Type `text` into a live pane."
  @spec tell(String.t(), String.t()) :: :ok | {:error, String.t()}
  def tell(pane, text) do
    cond do
      pane in Application.get_env(:babylon, :typing_panes, []) ->
        :typing

      pane in Application.get_env(:babylon, :live_panes, []) ->
        send(Application.fetch_env!(:babylon, :told_to), {:told, pane, text})
        :ok

      true ->
        {:error, "no pane #{pane}"}
    end
  end
end
