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

  @tag :tmp_dir
  test "an archive file already there is never written over", %{tmp_dir: dir} do
    machine = Repo.insert!(%Machine{name: "vault-keep"})
    at = ~U[2020-02-15 10:00:00.000000Z]
    Logs.ensure_partition(at)

    Repo.insert_all(Log, [
      %{
        at: at,
        received_at: at,
        level: "info",
        msg: "late",
        fields: %{},
        cut: false,
        machine_id: machine.id
      }
    ])

    path = Path.join(dir, "logs-2020-02.ndjson.gz")
    File.write!(path, "the real file")
    assert [^path] = Logs.archive(dir, ~D[2026-10-06])
    assert File.read!(path) == "the real file"
    assert Repo.aggregate(Log, :count) == 0
  end

  test "a month's partition is bounded in UTC whatever the session zone" do
    Repo.query!("SET LOCAL TIME ZONE 'America/Los_Angeles'")
    :persistent_term.erase({Logs, {2019, 3}})
    Logs.ensure_partition(~U[2019-03-15 10:00:00Z])
    Repo.query!("SET LOCAL TIME ZONE 'UTC'")

    assert %{rows: [[bound]]} =
             Repo.query!(
               "SELECT pg_get_expr(relpartbound, oid) FROM pg_class WHERE relname = 'logs_y2019m03'"
             )

    assert bound =~ "2019-03-01 00:00:00+00"
  end
end
