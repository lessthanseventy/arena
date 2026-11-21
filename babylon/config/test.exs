import Config

config :babylon, panes: Babylon.PanesStub

config :babylon, Babylon.Repo,
  database: Path.expand("../babylon_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5,
  log: false

config :logger, level: :warning
