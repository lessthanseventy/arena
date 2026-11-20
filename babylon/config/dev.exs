import Config

config :babylon, Babylon.Repo, database: Path.expand("../babylon_dev.db", __DIR__), pool_size: 5
