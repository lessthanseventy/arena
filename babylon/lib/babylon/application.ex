defmodule Babylon.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [Babylon.Repo, {Babylon.MCP.Server, transport: {:streamable_http, start: true}}] ++ listener()

    Supervisor.start_link(children, strategy: :one_for_one, name: Babylon.Supervisor)
  end

  # loopback only: nothing off the machine reaches it. A short drain, as an MCP client reconnects on its own.
  defp listener do
    if Application.get_env(:babylon, :serve, false) do
      [
        {Bandit,
         plug: {Anubis.Server.Transport.StreamableHTTP.Plug, server: Babylon.MCP.Server},
         ip: {127, 0, 0, 1},
         port: Application.fetch_env!(:babylon, :port),
         thousand_island_options: [shutdown_timeout: 2_000]},
        Babylon.Lapse
      ]
    else
      []
    end
  end
end
