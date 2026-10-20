defmodule Dokkit.Demo.SampleTest do
  use Dokkit.DataCase, async: false

  test "the hourly rebuild empties everything a visitor changed and builds the company again" do
    Dokkit.Demo.Sample.reset()
    Dokkit.Repo.insert!(%Dokkit.Machine{name: "added-by-a-visitor", kind: :seen})
    Dokkit.Demo.Sample.reset()

    names = Dokkit.Repo.all(Dokkit.Machine) |> Enum.map(& &1.name) |> Enum.sort()
    assert "db-01" in names
    refute "added-by-a-visitor" in names
    assert length(Dokkit.Accounts.list()) == 1
  end
end
