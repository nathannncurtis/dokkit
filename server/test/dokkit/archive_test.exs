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
  test "a month loaded back stays as many days as Settings says", %{tmp_dir: dir} do
    machine = Repo.insert!(%Machine{name: "vault-days"})
    at = ~U[2018-05-15 10:00:00.000000Z]
    Logs.ensure_partition(at)

    Repo.insert_all(Log, [
      %{
        at: at,
        received_at: at,
        level: "info",
        msg: "x",
        fields: %{},
        cut: false,
        machine_id: machine.id
      }
    ])

    [path] = Logs.archive(dir, ~D[2026-10-06])
    {:ok, _} = Dokkit.Values.save(:server, %{"restored_days" => 2})
    assert Logs.restore(path) == 1
    [%{back_until: until}] = Logs.archives(dir)
    assert DateTime.diff(until, DateTime.utc_now()) in (2 * 86_400 - 60)..(2 * 86_400)
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
    assert [other] = Logs.archive(dir, ~D[2026-10-06])
    assert Path.basename(other) == "logs-2020-02.2.ndjson.gz"
    assert File.read!(path) == "the real file"
    assert Repo.aggregate(Log, :count) == 0
  end

  defp old_line(machine, at, msg) do
    Logs.ensure_partition(at)

    Repo.insert_all(Log, [
      %{
        at: at,
        received_at: at,
        level: "info",
        msg: msg,
        fields: %{},
        cut: false,
        machine_id: machine.id
      }
    ])
  end

  @tag :tmp_dir
  test "lines that come for a month after its loaded-back copy is dropped are archived", %{
    tmp_dir: dir
  } do
    machine = Repo.insert!(%Machine{name: "vault-late"})
    at = ~U[2020-04-15 10:00:00.000000Z]
    old_line(machine, at, "first")
    assert [path] = Logs.archive(dir, ~D[2026-10-06])
    assert Logs.restore(path) == 1
    Dokkit.Setting.put("restored", %{"logs-2020-04" => "2020-01-01T00:00:00Z"})
    assert [^path] = Logs.archive(dir, ~D[2026-10-06])
    assert Dokkit.Setting.get("restored") == %{}

    old_line(machine, at, "late")
    assert [late] = Logs.archive(dir, ~D[2026-10-06])
    assert Path.basename(late) == "logs-2020-04.2.ndjson.gz"
    assert :zlib.gunzip(File.read!(late)) =~ "late"
  end

  @tag :tmp_dir
  test "a loaded-back second archive of a month holds the month", %{tmp_dir: dir} do
    machine = Repo.insert!(%Machine{name: "vault-two"})
    at = ~U[2020-05-15 10:00:00.000000Z]
    File.write!(Path.join(dir, "logs-2020-05.ndjson.gz"), :zlib.gzip(""))
    old_line(machine, at, "second")
    assert [path] = Logs.archive(dir, ~D[2026-10-06])
    assert Path.basename(path) == "logs-2020-05.2.ndjson.gz"
    assert Logs.restore(path) == 1
    assert Logs.archive(dir, ~D[2026-10-06]) == []
    assert Repo.aggregate(Log, :count) == 1
  end

  @tag :tmp_dir
  test "a restore that fails part way leaves no note and no rows", %{tmp_dir: dir} do
    machine = Repo.insert!(%Machine{name: "vault-fail"})
    at = ~U[2020-03-15 10:00:00.000000Z]
    line = %{"at" => DateTime.to_iso8601(at), "received_at" => DateTime.to_iso8601(at)}
    ok = Map.merge(line, %{"machine_id" => machine.id, "level" => "info", "msg" => "a"})
    bad = Map.put(ok, "level", nil)
    path = Path.join(dir, "logs-2020-03.ndjson.gz")
    File.write!(path, :zlib.gzip(Enum.map_join([ok, bad], "
", &Jason.encode!/1)))

    assert_raise Postgrex.Error, fn -> Logs.restore(path) end
    assert Repo.get(Dokkit.Setting, "restored").value == %{}
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
