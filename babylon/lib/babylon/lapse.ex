defmodule Babylon.Lapse do
  @moduledoc """
  Once a minute, lets go of the claims whose pane no longer runs Claude, and nudges again the panes
  with a message they have not read.
  """
  use GenServer

  require Logger

  @every to_timeout(minute: 1)

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil), do: {:ok, nil, {:continue, :sweep}}

  @impl true
  def handle_continue(:sweep, state), do: sweep(state)

  @impl true
  def handle_info(:sweep, state), do: sweep(state)

  defp sweep(state) do
    case Babylon.Claims.lapse(Babylon.Panes.claude()) do
      [] -> :ok
      ids -> Logger.info("claims lapsed: #{Enum.map_join(ids, ", ", &"##{&1}")}")
    end

    Babylon.Inbox.deliver_held()
    Babylon.Claims.name_sessions()
    Process.send_after(self(), :sweep, @every)
    {:noreply, state}
  end
end
