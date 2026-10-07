defmodule Dokkit.ReviewFixesTest do
  use DokkitWeb.ConnCase, async: false
  import Ecto.Query
  alias Dokkit.{Alert, Alerts, Check, Estate, Found, Issue, Issues, Keys, Machine, Numbers}
  alias Dokkit.{Read, Repo, Service}

  @late ~U[2026-01-10 23:30:00.000000Z]
  @morning ~U[2026-01-11 07:05:00.000000Z]

  setup do
    Alerts.save(%{
      "pagerduty_key" => "K",
      "night_from" => "22",
      "night_to" => "7",
      "degraded" => "push",
      "disk_limit" => "90"
    })

    Req.Test.stub(Alerts, fn conn -> Plug.Conn.send_resp(conn, 202, "{}") end)
    :ok
  end

  defp job(slug, config \\ %{}, attrs \\ []) do
    m =
      Repo.insert!(%Machine{
        name: "r-" <> slug,
        kind: :enrolled,
        last_seen_at: DateTime.utc_now()
      })

    s =
      Repo.insert!(
        struct!(
          Service,
          [machine_id: m.id, slug: slug, name: "Job " <> slug, kind: :job] ++ attrs
        )
      )

    c =
      Repo.insert!(%Check{
        service_id: s.id,
        name: slug,
        type: :job,
        fail_after: 1,
        config: config
      })

    {key, _} = Keys.mint(:machine, %{machine_id: m.id})
    {key, m, s, c}
  end

  defp line(slug, event, run, ms),
    do: %{type: "job", service: slug, name: slug, event: event, run: run, duration_ms: ms}

  defp issues(c), do: Repo.all(from i in Issue, where: i.check_id == ^c.id, order_by: i.since)
  defp alert(i), do: Repo.get_by!(Alert, issue_id: i.id)

  describe "a warning that becomes a failure" do
    test "a job that ran long and then fails is a new issue that pages" do
      {key, _, _, c} = job("esc", %{"max_runtime" => "1m"})
      report(key, [line("esc", "ok", "a", 120_000)])
      report(key, [line("esc", "fail", "b", 1000)])
      assert [%{soon: true, closed_at: %{}} = old, %{state: :down, soon: false} = new] = issues(c)
      assert new.title == "Job esc failed"
      assert alert(new).channel == "page"
      assert alert(old).status == :skipped
    end

    test "a page that turns into ran long is resolved" do
      {key, _, _, c} = job("unres", %{"max_runtime" => "1m"})
      report(key, [line("unres", "fail", "a", 1000)])
      assert Alerts.deliver_pending() == 1
      report(key, [line("unres", "ok", "b", 120_000)])
      assert [%{state: :down, closed_at: %{}} = old, %{soon: true, closed_at: nil}] = issues(c)
      assert alert(old).status == :closing
    end

    test "ran long, closed, then failed inside 30 minutes is not the old issue" do
      {key, _, _, c} = job("reop", %{"max_runtime" => "1m"})
      report(key, [line("reop", "ok", "a", 120_000)])
      report(key, [line("reop", "ok", "b", 1000)])
      report(key, [line("reop", "fail", "c", 1000)])
      open = Repo.all(from i in Issue, where: i.check_id == ^c.id and is_nil(i.closed_at))
      assert [%{state: :down, title: "Job reop failed"} = i] = open
      assert alert(i).channel == "page"
    end

    test "a degraded disk that reaches 98 percent pages as a new issue" do
      m = Repo.insert!(%Machine{name: "r-disk98", kind: :enrolled})
      at = DateTime.utc_now()
      for _ <- 1..3, do: Numbers.record(m.id, nil, "disk.used_percent.D", 91, at)

      assert [%{state: :degraded} = first] =
               Repo.all(from i in Issue, where: i.machine_id == ^m.id)

      assert alert(first).channel == "push"
      for _ <- 1..3, do: Numbers.record(m.id, nil, "disk.used_percent.D", 98.5, at)
      open = Repo.all(from i in Issue, where: i.machine_id == ^m.id and is_nil(i.closed_at))
      assert [%{state: :down} = down] = open
      assert alert(down).channel == "page"
    end

    test "an over-limit disk says how full it is, and the forecast is there from the first sweep" do
      m = Repo.insert!(%Machine{name: "r-disknote", kind: :enrolled})
      now = DateTime.utc_now()

      for {v, i} <- Enum.with_index([80, 82, 84, 86, 88, 90, 91]),
          do:
            Numbers.record(
              m.id,
              nil,
              "disk.used_percent.D",
              v,
              DateTime.add(now, (i - 6) * 86_400)
            )

      Numbers.record(m.id, nil, "disk.used_percent.D", 91.0, now)
      Numbers.record(m.id, nil, "disk.used_percent.D", 91.0, now)

      check =
        Repo.one!(
          from c in Check,
            where:
              c.name == "disk.used_percent.D" and
                c.service_id in subquery(
                  from s in Service, where: s.machine_id == ^m.id, select: s.id
                )
        )

      assert check.note == "It is 91 percent full. The limit is 90."
      Numbers.forecast(now)

      assert Repo.reload!(check).note =~
               "The limit is 90. At this week's rate it is full in about"
    end
  end

  test "a held alert is not sent for an issue that was snoozed or marked as seen" do
    {_, _, _, c} = job("heldsn", %{}, night: false)
    Issues.record(c, :down, at: @late, now: @late, title: "x failed")
    [issue] = issues(c)
    assert alert(issue).status == :held
    Issues.acknowledge(issue.id)
    assert Alerts.release(@morning) == 0
    assert alert(issue).status == :skipped
  end

  test "turning night alerts back on sends what is held" do
    {_, _, s, c} = job("wakeup", %{}, night: false)
    Issues.record(c, :down, at: @late, now: @late, title: "x failed")
    [issue] = issues(c)
    assert alert(issue).status == :held
    Estate.set_routing(s, %{"night" => true})
    assert alert(issue).status in [:pending, :sent, :failed]
  end

  test "routing and rules keep what is not given" do
    {_, _, s, _} = job("routes", %{}, route_down: "email", route_degraded: "digest")

    assert %{down: "email", degraded: "digest", night: false} =
             DokkitWeb.ApiController.set_routing(%{"id" => s.id, "night" => false})

    rule = List.last(Alerts.add_rule(%{"kind" => "job", "state" => "down", "channel" => "page"}))
    list = Alerts.update_rule(rule["id"], %{"on" => false})

    assert %{"kind" => "job", "state" => "down", "channel" => "page", "on" => false} =
             Enum.find(list, &(&1["id"] == rule["id"]))
  end

  test "a soon issue routed to page is sent as a push" do
    Alerts.save(%{"degraded" => "page"})
    {key, _, _, c} = job("soonpage", %{"max_runtime" => "1m"})
    report(key, [line("soonpage", "ok", "a", 120_000)])
    assert [%{soon: true} = i] = issues(c)
    assert alert(i).channel == "push"
  end

  test "the last day keeps what was sent after the issue closes" do
    {_, _, _, c} = job("daysent")
    now = DateTime.utc_now()
    Issues.record(c, :down, at: DateTime.add(now, -3600), title: "daysent failed")
    Alerts.deliver_pending()
    Issues.record(Repo.reload!(c), :ok, at: DateTime.add(now, -1800))
    assert %{sent: "Paged"} = Enum.find(Read.day(now).events, &(&1.title == "daysent failed"))
  end

  test "fine leaves out a machine that stopped reporting, and attention counts Needs you by machine" do
    before = Issues.fine()
    {_, m, s, c} = job("gone")
    Repo.update!(Ecto.Changeset.change(s, state: :ok))
    assert Issues.fine().services == before.services + 1
    Repo.update!(Ecto.Changeset.change(m, last_seen_at: DateTime.add(DateTime.utc_now(), -3600)))
    Issues.machines_sweep(DateTime.utc_now())
    assert Issues.fine() == before

    {_, m2, _, c2} = job("needs")
    Issues.record(c2, :down, title: "needs failed")
    assert %{} = counts = Issues.attention_by_machine()
    assert counts[m2.id] == 1
    assert Issues.open_count() == Enum.sum(Map.values(counts))
    assert c
  end

  test "a soon issue of another environment lists under Soon" do
    {key, _, _, c} = job("stg", %{"max_runtime" => "1m"}, environment: "staging")
    report(key, [line("stg", "ok", "a", 120_000)])
    g = Issues.groups()
    assert Enum.any?(g.soon, &(&1.check_id == c.id))
    refute Enum.any?(g.other, &(&1.check_id == c.id))
  end

  test "an issue from a plain state line is titled by the service" do
    m = Repo.insert!(%Machine{name: "r-title", kind: :enrolled})
    s = Repo.insert!(%Service{machine_id: m.id, slug: "postgres", name: "Postgres"})
    c = Repo.insert!(%Check{service_id: s.id, name: "up", type: :custom, fail_after: 1})
    Issues.record(c, :down)
    assert [%{title: "Postgres is down"}] = issues(c)
  end

  describe "the disk forecast" do
    defp disk(machine, name, values, now) do
      n = length(values)

      for {v, i} <- Enum.with_index(values),
          do: Numbers.record(machine.id, nil, name, v, DateTime.add(now, -(n - 1 - i) * 86_400))
    end

    defp open_for(m),
      do: Repo.all(from i in Issue, where: i.machine_id == ^m.id and is_nil(i.closed_at))

    test "its title changes while it is open" do
      m = Repo.insert!(%Machine{name: "r-title2", kind: :enrolled})
      now = DateTime.utc_now()
      disk(m, "disk.used_percent.D", [60, 62, 64, 66, 68, 70, 72, 74], now)
      Numbers.forecast(now)
      assert [%{title: "Disk D on r-title2 fills in about 8 days"}] = open_for(m)

      for d <- 1..5,
          do:
            Numbers.record(
              m.id,
              nil,
              "disk.used_percent.D",
              74 + 2 * d,
              DateTime.add(now, d * 86_400)
            )

      Numbers.forecast(DateTime.add(now, 5 * 86_400))
      assert [%{title: title}] = open_for(m)
      refute title =~ "8 days"
    end

    test "it closes when the limit is switched off" do
      m = Repo.insert!(%Machine{name: "r-off", kind: :enrolled})
      now = DateTime.utc_now()
      disk(m, "disk.used_percent.D", [60, 62, 64, 66, 68, 70, 72, 74], now)
      Numbers.forecast(now)
      assert [_] = open_for(m)
      Alerts.save(%{"disk_limit" => ""})
      Numbers.forecast(now)
      assert open_for(m) == []
    end

    test "it closes when the readings stop" do
      m = Repo.insert!(%Machine{name: "r-stop", kind: :enrolled})
      now = DateTime.utc_now()
      disk(m, "disk.used_percent.D", [60, 62, 64, 66, 68, 70, 72, 74], now)
      Numbers.forecast(now)
      assert [_] = open_for(m)
      Numbers.forecast(DateTime.add(now, 30 * 86_400))
      assert open_for(m) == []
    end

    test "it stays open a little past the edge it opened at" do
      m = Repo.insert!(%Machine{name: "r-edge", kind: :enrolled})
      now = DateTime.utc_now()
      # 1 percent a day from 77: the limit is 13 days away.
      disk(m, "disk.used_percent.D", [70, 71, 72, 73, 74, 75, 76, 77], now)
      Numbers.forecast(now)
      assert [_] = open_for(m)
      # 15 days away: still open. 20 days away: closed.
      Repo.delete_all(from x in Dokkit.Metric, where: x.machine_id == ^m.id)
      disk(m, "disk.used_percent.D", [68, 69, 70, 71, 72, 73, 74, 75], now)
      Numbers.forecast(now)
      assert [_] = open_for(m)
      Repo.delete_all(from x in Dokkit.Metric, where: x.machine_id == ^m.id)
      disk(m, "disk.used_percent.D", [63, 64, 65, 66, 67, 68, 69, 70], now)
      Numbers.forecast(now)
      assert open_for(m) == []
    end

    test "full in N days has an upper bound" do
      m = Repo.insert!(%Machine{name: "r-bound", kind: :enrolled})
      now = DateTime.utc_now()
      disk(m, "disk.used_percent.D", [90.5, 90.51, 90.52, 90.53, 90.54, 90.55, 90.56, 90.57], now)
      Numbers.record(m.id, nil, "disk.used_percent.D", 91, now)
      Numbers.forecast(now)

      check =
        Repo.one!(
          from c in Check,
            join: s in assoc(c, :service),
            where: s.machine_id == ^m.id and c.name == "disk.used_percent.D"
        )

      refute check.config["full_in_days"]
    end
  end

  describe "found" do
    test "a task listed twice in one scan is kept once" do
      m = Repo.insert!(%Machine{name: "r-dup", kind: :enrolled})

      body = %{
        "os" => "windows",
        "found" => %{"tasks" => [%{"name" => "\\Backup"}, %{"name" => "\\Backup"}]}
      }

      assert {:ok, 1} = Found.propose(m.id, body)

      ports = %{
        "os" => "windows",
        "found" => %{"ports" => [%{"port" => 5432}, %{"port" => "5432"}]}
      }

      assert {:ok, 2} = Found.propose(m.id, ports)
    end

    test "a watched task waits for its first report and is not late until then" do
      m =
        Repo.insert!(%Machine{name: "r-wait", kind: :enrolled, last_seen_at: DateTime.utc_now()})

      {:ok, _} =
        Found.propose(m.id, %{
          "os" => "windows",
          "found" => %{"tasks" => [%{"name" => "\\Backup", "schedule" => "0 * * * *"}]}
        })

      [f] = Repo.all(from f in Dokkit.Finding, where: f.machine_id == ^m.id)
      assert f.detail["saw"] =~ "dokkit run --job backup -- <command>"
      Found.watch([f.id])

      check =
        Repo.one!(from c in Check, join: s in assoc(c, :service), where: s.machine_id == ^m.id)

      reported = ~U[2026-03-10 12:20:00.000000Z]
      now = ~U[2026-03-10 13:45:00.000000Z]

      Repo.update_all(from(c in Check, where: c.id == ^check.id),
        set: [inserted_at: DateTime.add(reported, -7200)]
      )

      assert Dokkit.Watch.sweep(now) == 0
      assert Repo.reload!(check).state == :unknown

      {_, key} = Keys.mint(:machine, %{machine_id: m.id})
      body = Jason.encode!(line("backup", "ok", "a", 1000))
      assert {:ok, _} = Dokkit.Intake.report(key, nil, body, reported)
      refute Repo.reload!(check).config["waiting"]
      assert Dokkit.Watch.sweep(now) == 1
    end
  end

  test "a job declared before its due time is flagged once it is late" do
    {_, _, _, c} = job("today", %{"schedule" => "0 6 * * *", "grace" => "30m"})
    now = DateTime.utc_now()

    Repo.update_all(from(k in Check, where: k.id == ^c.id),
      set: [inserted_at: %{now | hour: 5, minute: 0}]
    )

    assert Dokkit.Watch.sweep(%{now | hour: 7, minute: 0}) == 1
  end

  test "durations are worded in minutes and hours past two minutes" do
    assert DokkitWeb.Show.took(45_000) == "45 s"
    assert DokkitWeb.Show.took(110_000) == "110 s"
    assert DokkitWeb.Show.took(240_000) == "4 minutes"
    assert DokkitWeb.Show.took(10_800_000) == "3 hours"
    assert DokkitWeb.Show.took(5_400_000) == "90 minutes"
  end
end
