import Config

config :babylon, Babylon.Repo,
  database: "babylon_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5,
  log: false

config :logger, level: :warning
