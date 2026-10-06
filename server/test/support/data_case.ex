defmodule Dokkit.DataCase do
  @moduledoc "Tests that use the database run inside a sandbox that is rolled back afterwards."
  use ExUnit.CaseTemplate

  setup tags do
    Dokkit.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Dokkit.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
