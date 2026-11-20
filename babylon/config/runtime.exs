import Config

if config_env() == :prod do
  state = System.get_env("XDG_STATE_HOME") || Path.join(System.fetch_env!("HOME"), ".local/state")
  config :babylon, Babylon.Repo, database: Path.join(state, "babylon/babylon.db")
end

if config_env() != :test do
  board_dir =
    System.get_env("XDG_RUNTIME_DIR") || System.get_env("XDG_STATE_HOME") ||
      Path.join(System.fetch_env!("HOME"), ".local/state")

  home = System.fetch_env!("HOME")

  config :babylon, :pipeline,
    projects: System.get_env("BABYLON_PROJECTS") || Path.join(home, "projects"),
    work: Path.join(System.get_env("XDG_CACHE_HOME") || Path.join(home, ".cache"), "babylon/work")

  config :babylon,
    board: Path.join(board_dir, "babylon/board.json"),
    serve: System.get_env("BABYLON_SERVE") in ~w(1 true yes),
    port: String.to_integer(System.get_env("BABYLON_PORT") || "4050")
end
