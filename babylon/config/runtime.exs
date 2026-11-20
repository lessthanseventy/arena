import Config

if config_env() == :prod do
  state = System.get_env("XDG_STATE_HOME") || Path.join(System.fetch_env!("HOME"), ".local/state")
  config :babylon, Babylon.Repo, database: Path.join(state, "babylon/babylon.db")
end

if config_env() != :test do
  config :babylon,
    serve: System.get_env("BABYLON_SERVE") in ~w(1 true yes),
    port: String.to_integer(System.get_env("BABYLON_PORT") || "4050")
end
