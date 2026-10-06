defmodule Dokkit.DataCase do
  @moduledoc "Tests that use the database run inside a sandbox that is rolled back afterwards."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Dokkit.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
    end
  end

  setup tags do
    Dokkit.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Dokkit.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
