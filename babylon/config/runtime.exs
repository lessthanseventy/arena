import Config

if config_env() != :test do
  config :babylon,
    serve: System.get_env("BABYLON_SERVE") in ~w(1 true yes),
    port: String.to_integer(System.get_env("BABYLON_PORT") || "4050")
end
