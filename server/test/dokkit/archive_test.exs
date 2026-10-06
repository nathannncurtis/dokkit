defmodule Dokkit.ArchiveTest do
  # Not async: dropping a month locks the whole logs table.
  use Dokkit.DataCase
  alias Dokkit.{Log, Logs, Machine, Repo}

  @tag :tmp_dir
  test "a month older than a year becomes one file, and the file loads back", %{tmp_dir: dir} do
    machine = Repo.insert!(%Machine{name: "vault"})
    at = ~U[2020-01-15 10:00:00.000000Z]
    Logs.ensure_partition(at)

    Repo.insert_all(Log, [
      %{
        at: at,
        received_at: at,
        level: "error",
        msg: "an old line",
        fields: %{"a" => 1},
        cut: false,
        machine_id: machine.id
      }
    ])

    assert [path] = Logs.archive(dir, ~D[2026-10-06])
    assert Path.basename(path) == "logs-2020-01.ndjson.gz"
    assert Logs.archive(dir, ~D[2026-10-06]) == []
    assert Repo.aggregate(Log, :count) == 0

    assert [%{name: "logs-2020-01", back_until: nil}] = Logs.archives(dir)
    assert Logs.restore(path) == 1
    # Loaded back, it stays a week: not archived again, and not loaded twice.
    assert Logs.archive(dir, ~D[2026-10-06]) == []
    assert Logs.restore(path) == 0
    assert [%{back_until: %DateTime{}}] = Logs.archives(dir)
    assert [%{msg: "an old line", level: "error", fields: %{"a" => 1}, at: ^at}] = Repo.all(Log)
  end
end
