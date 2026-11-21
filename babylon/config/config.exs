import Config

config :babylon, ecto_repos: [Babylon.Repo]

# immediate: a transaction takes the write lock as it begins, so a claim's read and write are one step
config :babylon, Babylon.Repo, default_transaction_mode: :immediate

config :babylon, notify: ~w(notify-send -a babylon --)

config :babylon, :pipeline,
  gates: 2,
  train: 4,
  gate: ~w(mise run check),
  gate_timeout: 1800,
  reviewer: [
    "claude",
    "-p",
    "--model",
    "claude-sonnet-5-5",
    "--no-session-persistence",
    "--permission-mode",
    "acceptEdits",
    "--strict-mcp-config",
    "--mcp-config",
    ~s({"mcpServers":{}}),
    "--tools",
    "Read,Grep,Glob,Edit,Write",
    "--setting-sources",
    "user"
  ],
  review_timeout: 900,
  tmux: []

import_config "#{config_env()}.exs"
