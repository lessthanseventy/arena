defmodule Babylon.DataCase do
  @moduledoc """
  A test case with its own sandboxed connection to the test database. Not async: SQLite has one
  writer, and a sandboxed test holds its write transaction for as long as it runs.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Babylon.DataCase
      alias Babylon.Repo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Babylon.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc "A changeset's errors as `%{field => [message]}`, with their values put in."
  @spec errors_on(Ecto.Changeset.t()) :: %{atom() => [String.t()]}
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
