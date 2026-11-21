defmodule Babylon.Notice do
  @moduledoc """
  A desktop notice for the human, as arena raises its own, where there is a notifier; the
  orchestrator is told the same.
  """

  @doc """
  Show `text` with the notifier configured as `:notify` (nothing where it is not installed), and
  tell the orchestrator.
  """
  @spec show(String.t()) :: :ok
  def show(text) do
    with [exe | args] <- Application.fetch_env!(:babylon, :notify),
         path when is_binary(path) <- System.find_executable(exe) do
      System.cmd(path, args ++ [text], stderr_to_stdout: true)
    end

    Babylon.Orchestrator.tell(text)
  end
end
