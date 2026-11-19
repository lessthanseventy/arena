import Config

config :babylon, ecto_repos: [Babylon.Repo]

config :babylon, Babylon.Repo, socket_dir: System.get_env("PGHOST") || "/run/postgresql"

import_config "#{config_env()}.exs"
