defmodule Babylon.Repo do
  use Ecto.Repo, otp_app: :babylon, adapter: Ecto.Adapters.SQLite3
end
