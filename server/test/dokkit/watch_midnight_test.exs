defmodule Dokkit.WatchMidnightTest do
  use Dokkit.DataCase, async: false
  alias Dokkit.{Check, JobRun, Machine, Repo, Service, Watch}

  defp job(schedule, declared, grace \\ "30m") do
    m = Repo.insert!(%Machine{name: "mid-#{System.unique_integer([:positive])}", kind: :enrolled})

    s =
      Repo.insert!(%Service{machine_id: m.id, slug: "j#{m.id}", name: "J#{m.id}", kind: :job})

    Repo.insert!(%Check{
      service_id: s.id,
      name: "j",
      type: :job,
      fail_after: 1,
      config: %{"schedule" => schedule, "grace" => grace},
      inserted_at: declared
    })
  end

  defp ran(check, at),
    do:
      Repo.insert!(%JobRun{
        check_id: check.id,
        run: Ecto.UUID.generate(),
        result: :ok,
        started_at: at,
        finished_at: at
      })

  defp flagged(check, now) do
    Watch.sweep(now)
    Repo.reload!(check).state == :down
  end

  @old ~U[2025-06-01 00:00:00.000000Z]

  test "hourly: last run 23:55, swept 00:45 the next day, is late" do
    c = job("0 * * * *", @old)
    ran(c, ~U[2026-03-10 23:55:00.000000Z])
    assert flagged(c, ~U[2026-03-11 00:45:00.000000Z])
  end

  test "hourly: a run at 00:00 is not late at 00:45" do
    c = job("0 * * * *", @old)
    ran(c, ~U[2026-03-11 00:00:30.000000Z])
    refute flagged(c, ~U[2026-03-11 00:45:00.000000Z])
  end

  test "daily 00:10 with last good run the previous day is late at 00:45" do
    c = job("10 0 * * *", @old)
    ran(c, ~U[2026-03-10 00:10:00.000000Z])
    assert flagged(c, ~U[2026-03-11 00:45:00.000000Z])
  end

  test "daily 00:10 is not late inside grace" do
    c = job("10 0 * * *", @old)
    ran(c, ~U[2026-03-10 00:10:00.000000Z])
    refute flagged(c, ~U[2026-03-11 00:30:00.000000Z])
  end

  test "daily 23:50 swept 00:30 the next day is late (grace 30m)" do
    c = job("50 23 * * *", @old)
    ran(c, ~U[2026-03-09 23:50:00.000000Z])
    assert flagged(c, ~U[2026-03-11 00:30:00.000000Z])
  end

  test "daily 23:50 that ran at 23:50 is not late at 00:30" do
    c = job("50 23 * * *", @old)
    ran(c, ~U[2026-03-10 23:50:10.000000Z])
    refute flagged(c, ~U[2026-03-11 00:30:00.000000Z])
  end

  test "declared 23:58, due 00:00, late at 00:45" do
    c = job("0 0 * * *", ~U[2026-03-10 23:58:00.000000Z])
    assert flagged(c, ~U[2026-03-11 00:45:00.000000Z])
  end

  test "declared 23:58, due 00:00, not yet late at 00:20" do
    c = job("0 0 * * *", ~U[2026-03-10 23:58:00.000000Z])
    refute flagged(c, ~U[2026-03-11 00:20:00.000000Z])
  end

  test "weekly Sunday 00:00, swept Sunday 00:45, is late" do
    c = job("0 0 * * 0", @old)
    ran(c, ~U[2026-03-01 00:00:00.000000Z])
    assert flagged(c, ~U[2026-03-08 00:45:00.000000Z])
  end

  test "monthly on the 1st at 00:00, swept at the month boundary" do
    c = job("0 0 1 * *", @old)
    ran(c, ~U[2026-02-01 00:00:00.000000Z])
    assert flagged(c, ~U[2026-03-01 00:45:00.000000Z])
  end

  test "monthly across a year boundary" do
    c = job("0 0 1 * *", @old)
    ran(c, ~U[2025-12-01 00:00:00.000000Z])
    assert flagged(c, ~U[2026-01-01 00:45:00.000000Z])
  end

  test "hourly across new year" do
    c = job("0 * * * *", @old)
    ran(c, ~U[2026-12-31 23:55:00.000000Z])
    assert flagged(c, ~U[2027-01-01 00:45:00.000000Z])
  end

  # A run reported in the minute before the due time counts for that due time (early start).
  for {label, reported, swept, late} <- [
        {"just before midnight", ~U[2026-03-10 23:55:00.123456Z], ~U[2026-03-11 00:45:00.000000Z],
         1},
        {"in the last minute (counts as the 00:00 run)", ~U[2026-03-10 23:59:30.000000Z],
         ~U[2026-03-11 00:45:00.000000Z], 0},
        {"mid-day", ~U[2026-03-10 12:55:00.000000Z], ~U[2026-03-10 13:45:00.000000Z], 1},
        {"in the last minute of a mid-day hour", ~U[2026-03-10 12:59:30.000000Z],
         ~U[2026-03-10 13:45:00.000000Z], 0}
      ] do
    test "a hourly job reported #{label}: #{late} late" do
      check = job("0 * * * *", @old)
      ran(check, unquote(Macro.escape(reported)))
      assert Watch.sweep(unquote(Macro.escape(swept))) == unquote(late)
    end
  end

  test "daily 01:00 swept 01:45 the next day, last run the day before" do
    c = job("0 1 * * *", @old)
    ran(c, ~U[2026-03-10 01:00:00.000000Z])
    assert flagged(c, ~U[2026-03-11 01:45:00.000000Z])
  end
end
