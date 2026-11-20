import Config

config :babylon, ecto_repos: [Babylon.Repo]

# immediate: a transaction takes the write lock as it begins, so a claim's read and write are one step
config :babylon, Babylon.Repo, default_transaction_mode: :immediate

import_config "#{config_env()}.exs"
