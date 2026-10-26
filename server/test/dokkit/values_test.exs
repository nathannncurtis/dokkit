defmodule Dokkit.ValuesTest do
  # Each test changes a setting and watches the code that reads it behave differently.
  use DokkitWeb.ConnCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Dokkit.{
    Alert,
    Alerts,
    Check,
    Errors,
    Issue,
    Issues,
    JobRun,
    Keys,
    Logs,
    Machine,
    Metric,
    Numbers,
    Quiet,
    Repo,
    Service,
    Values,
    Watch
  }

  defp machine(name, attrs \\ []),
    do: Repo.insert!(struct!(Machine, [name: name, kind: :enrolled] ++ attrs))

  defp service(m, slug, attrs \\ []),
    do: Repo.insert!(struct!(Service, [machine_id: m.id, slug: slug, name: slug] ++ attrs))

  defp check(s, attrs),
    do: Repo.insert!(struct!(Check, [service_id: s.id, name: "c", type: :custom] ++ attrs))

  defp set(scope \\ :server, values), do: {:ok, _} = Values.save(scope, values)

  defp machine_check(m, name) do
    Repo.one(
      from c in Check,
        join: s in assoc(c, :service),
        where: s.machine_id == ^m.id and c.name == ^name
    )
  end

  describe "the values themselves" do
    test "a value keeps its default until changed, and Reset brings it back" do
      assert Values.get("send_tries") == 5
      set(%{"send_tries" => "7"})
      assert Values.get("send_tries") == 7

      assert %{"changed" => ["send_tries"], "defaults" => %{"send_tries" => 5}} =
               Values.view(:server)

      {:ok, _} = Values.reset(:server, "tries")
      assert Values.get("send_tries") == 5
      assert Values.view(:server)["changed"] == []
    end

    test "bad values and unknown names are refused, and nothing is saved" do
      assert {:error, "send_tries is a whole number from 1 to 20."} =
               Values.save(:server, %{"send_tries" => 0})

      assert {:error, "nope is not a setting."} = Values.save(:server, %{"nope" => 1})

      assert {:error, "session_days is not a setting for a machine."} =
               Values.save({:machine, Ecto.UUID.generate()}, %{"session_days" => 3})

      assert {:error, "enrol_hours is at most enrol_max_hours."} =
               Values.save(:server, %{"enrol_hours" => 80})

      assert {:error, _} = Values.save(:server, %{"snooze_choices" => "soon"})
      assert {:error, _} = Values.save(:server, %{"quiet_choices" => "9h"})
      assert Values.view(:server)["changed"] == []
    end

    test "a machine starts at the server's value, keeps its own, and goes back on Reset" do
      m = machine("v-scope")
      set(%{"silent_minutes" => 6})
      assert Values.get("silent_minutes", {:machine, m.id}) == 6
      set({:machine, m.id}, %{"silent_minutes" => 12})
      set(%{"silent_minutes" => 8})
      assert Values.get("silent_minutes", {:machine, m.id}) == 12
      # The same value as the server's is no change of its own.
      set({:machine, m.id}, %{"silent_minutes" => 8})
      assert Values.own({:machine, m.id}) == %{}
    end

    test "the disk and memory limits are the ones on the Alerts page" do
      set(%{"disk_limit" => 80})
      assert Alerts.config()["disk_limit"] == "80"
      set(%{"memory_on" => false})
      assert Alerts.config()["memory_limit"] == ""
      Alerts.save(%{"disk_limit" => "70"})
      assert %{"disk_limit" => 70, "memory_on" => false} = Values.all()
      {:ok, _} = Values.reset(:server, "disk")
      assert Alerts.config()["disk_limit"] == "90"
    end
  end

  describe "machines" do
    test "a machine's own disk limit, readings in a row and down level are used" do
      m = machine("v-disk")
      other = machine("v-disk-2")
      set({:machine, m.id}, %{"disk_limit" => 50, "disk_after" => 1, "disk_down" => 60})
      now = DateTime.utc_now()

      Numbers.record(m.id, nil, "disk.used_percent.C", 55, now)
      Numbers.record(other.id, nil, "disk.used_percent.C", 55, now)
      assert machine_check(m, "disk.used_percent.C").state == :degraded
      refute machine_check(other, "disk.used_percent.C").state == :degraded

      Numbers.record(m.id, nil, "disk.used_percent.C", 65, now)
      assert machine_check(m, "disk.used_percent.C").state == :down
      assert Dokkit.Read.machine(m.id).thresholds.disk_used_percent == "50"
    end

    test "a machine's own limit replaces a threshold its dokkit.toml declares" do
      m = machine("v-toml")
      {mkey, _} = Keys.mint(:machine, %{machine_id: m.id})

      doc = %{
        schema: 1,
        service: %{id: "files", name: "Files"},
        check: [%{type: "threshold", name: "disk", metric: "disk.used_percent.D", limit: 99}]
      }

      put_req_header(build_conn(), "authorization", "Bearer " <> mkey)
      |> put("/api/v1/declare", doc)
      |> json_response(200)

      now = DateTime.utc_now()
      Numbers.record(m.id, nil, "disk.used_percent.D", 95, now)
      refute machine_check(m, "disk.used_percent.D")

      set({:machine, m.id}, %{"disk_limit" => 80, "disk_after" => 1})
      Numbers.record(m.id, nil, "disk.used_percent.D", 95, now)
      assert %{state: :degraded} = machine_check(m, "disk.used_percent.D")
    end

    test "memory follows its own limit and down level" do
      m = machine("v-mem")
      set({:machine, m.id}, %{"memory_limit" => 40, "memory_after" => 2, "memory_down" => 99})
      now = DateTime.utc_now()
      Numbers.record(m.id, nil, "memory.used_percent", 60, now)
      refute machine_check(m, "memory.used_percent").state == :degraded
      Numbers.record(m.id, nil, "memory.used_percent", 60, now)
      assert machine_check(m, "memory.used_percent").state == :degraded
    end

    test "the processor alert is on at 90% for 10 minutes, can be switched off, and counts its minutes" do
      m = machine("v-cpu")
      off = machine("v-cpu-off")
      now = DateTime.utc_now()
      set({:machine, off.id}, %{"cpu_on" => false})
      Numbers.record(off.id, nil, "cpu.percent", 99, now)
      refute machine_check(off, "cpu.percent")

      for _ <- 1..9, do: Numbers.record(m.id, nil, "cpu.percent", 95, now)
      refute machine_check(m, "cpu.percent").state == :degraded
      Numbers.record(m.id, nil, "cpu.percent", 95, now)
      assert %{state: :degraded} = machine_check(m, "cpu.percent")
      assert [%{title: "The processor is busy"}] = Issues.open_list()

      own = machine("v-cpu-own")
      set({:machine, own.id}, %{"cpu_limit" => 50, "cpu_minutes" => 2})
      Numbers.record(own.id, nil, "cpu.percent", 70, now)
      refute machine_check(own, "cpu.percent").state == :degraded
      Numbers.record(own.id, nil, "cpu.percent", 70, now)
      assert %{state: :degraded} = machine_check(own, "cpu.percent")
    end

    test "each machine goes quiet after its own number of minutes" do
      now = DateTime.utc_now()
      a = machine("v-quiet-a", last_seen_at: DateTime.add(now, -300))
      b = machine("v-quiet-b", last_seen_at: DateTime.add(now, -300))
      set({:machine, a.id}, %{"silent_minutes" => 10})
      Issues.machines_sweep(now)
      assert [%{machine_id: id}] = Repo.all(from i in Issue, where: i.kind == "machine")
      assert id == b.id
    end

    test "the disk forecast looks as far ahead as the machine says" do
      now = DateTime.utc_now()
      a = machine("v-fc-a")
      b = machine("v-fc-b")

      for m <- [a, b],
          i <- 0..7,
          do:
            Numbers.record(
              m.id,
              nil,
              "disk.used_percent.D",
              50 + 2 * i,
              DateTime.add(now, -(7 - i) * 86_400 + 60)
            )

      set({:machine, b.id}, %{"forecast_days" => 10})
      Numbers.forecast(now)
      assert %{state: :degraded} = machine_check(a, "forecast.disk.used_percent.D")
      refute machine_check(b, "forecast.disk.used_percent.D")

      set(%{"forecast_min_days" => 8, "forecast_window_days" => 9})
      Numbers.forecast(now)
      assert %{state: :ok} = machine_check(a, "forecast.disk.used_percent.D")
    end

    test "the program is sent its reporting and scanning values with its checks" do
      m = machine("v-prog")
      {mkey, _} = Keys.mint(:machine, %{machine_id: m.id})
      set(%{"check_timeout_seconds" => 9, "expiry_days" => 20, "restart_gap_minutes" => 3})
      set({:machine, m.id}, %{"report_seconds" => 30, "scan_every_hours" => 6})

      assert %{
               "settings" => %{
                 "report_seconds" => 30,
                 "scan_first_seconds" => 120,
                 "scan_every_seconds" => 21_600,
                 "check_every_seconds" => 30,
                 "check_timeout_seconds" => 9,
                 "expiry_days" => 20,
                 "restart_gap_seconds" => 180
               }
             } =
               build_conn()
               |> put_req_header("authorization", "Bearer " <> mkey)
               |> get("/api/v1/checks")
               |> json_response(200)
    end

    test "planned downtime takes the longest and the lengths from Settings" do
      assert Quiet.parse("6h") == :error
      set(%{"quiet_max_hours" => 8, "quiet_choices" => "1h, 8h"})
      assert Quiet.parse("6h") == {:ok, 21_600}
      assert DokkitWeb.QuietBand.lengths() == [{"1h", "1 hour"}, {"8h", "8 hours"}]
    end
  end

  describe "checks" do
    test "a check that does not say how many failures it needs uses the server's number" do
      s = service(machine("v-fail"), "app")
      plain = check(s, name: "plain")
      own = check(s, name: "own", config: %{"own_fail_after" => true})
      set(%{"check_fail_after" => 1})
      Issues.record(plain, :down)
      Issues.record(own, :down)
      assert Repo.reload!(plain).state == :down
      refute Repo.reload!(own).state == :down
    end

    test "a problem reopens its old issue only within the minutes set" do
      s = service(machine("v-reopen"), "app")
      c = check(s, fail_after: 1)
      t = DateTime.utc_now()
      Issues.record(c, :down, at: t)
      Issues.record(Repo.reload!(c), :ok, at: DateTime.add(t, 60))
      Issues.record(Repo.reload!(c), :down, at: DateTime.add(t, 120))
      assert Repo.aggregate(Issue, :count) == 1

      set(%{"reopen_minutes" => 0})
      Issues.record(Repo.reload!(c), :ok, at: DateTime.add(t, 180))
      Issues.record(Repo.reload!(c), :down, at: DateTime.add(t, 240))
      assert Repo.aggregate(Issue, :count) == 2
    end

    test "Dokkit waits as long as Settings says after it starts" do
      now = DateTime.utc_now()
      refute Watch.settled?(DateTime.add(now, -120), now)
      set(%{"warmup_minutes" => 1})
      assert Watch.settled?(DateTime.add(now, -120), now)
    end

    test "a heartbeat goes quiet after the beats and seconds set" do
      s = service(machine("v-beat"), "worker")
      now = DateTime.utc_now()

      beat =
        check(s,
          type: :beat,
          fail_after: 1,
          config: %{"every_seconds" => 30},
          checked_at: now
        )

      set(%{"beat_misses" => 4})
      assert Watch.sweep(DateTime.add(now, 130)) == 0
      set(%{"beat_misses" => 2, "beat_slack_seconds" => 0})
      assert Watch.sweep(DateTime.add(now, 70)) == 1
      assert Repo.reload!(beat).state == :down
    end
  end

  describe "jobs" do
    defp job(name, config) do
      s = service(machine(name), name, kind: :job)

      c =
        check(s,
          name: name,
          type: :job,
          fail_after: 1,
          config: config,
          inserted_at: ~U[2026-10-01 00:00:00.000000Z]
        )

      {s, c}
    end

    @now ~U[2026-10-06 02:40:00.000000Z]

    test "grace and whether a missed run alerts are per job" do
      {a, _} = job("v-job-a", %{"schedule" => "0 2 * * *"})
      {b, _} = job("v-job-b", %{"schedule" => "0 2 * * *"})
      {c, _} = job("v-job-c", %{"schedule" => "0 2 * * *"})
      set({:job, b.id}, %{"job_grace_minutes" => 60})
      set({:job, c.id}, %{"job_missed" => false})
      assert Watch.sweep(@now) == 1
      assert Repo.reload!(a).state == :down
    end

    test "a job's own setting replaces the grace in its file" do
      {s, _} = job("v-job-own", %{"schedule" => "0 2 * * *", "grace" => "10m"})
      assert Values.view({:job, s.id})["defaults"]["job_grace_minutes"] == 10
      set({:job, s.id}, %{"job_grace_minutes" => 50})
      assert Watch.sweep(@now) == 0
    end

    test "too long is off by default, and on it flags a run past its minutes" do
      {_, c} = job("v-job-long", %{})
      started = DateTime.add(DateTime.utc_now(), -90 * 60)
      Repo.insert!(%JobRun{check_id: c.id, run: "r", result: :running, started_at: started})
      assert Watch.sweep() == 0
      set(%{"job_max_on" => true})
      assert Watch.sweep() == 1
    end

    test "runs are kept for the days set, for the server or one job" do
      {s, c} = job("v-job-keep", %{})
      now = DateTime.utc_now()

      for {run, days} <- [{"old", 40}, {"good", 1}, {"new", 0}],
          do:
            Repo.insert!(%JobRun{
              check_id: c.id,
              run: run,
              result: :ok,
              started_at: DateTime.add(now, -days * 86_400),
              finished_at: DateTime.add(now, -days * 86_400 + 1)
            })

      Watch.prune(now)
      assert Repo.aggregate(JobRun, :count) == 3
      set({:job, s.id}, %{"job_keep_days" => 30})
      Watch.prune(now)
      assert Repo.aggregate(JobRun, :count) == 2
    end
  end

  describe "keeping" do
    test "readings, process lists, heard-from slots and unknown hosts go after their time" do
      m = machine("v-keep")
      now = DateTime.utc_now()

      Repo.insert!(%Metric{
        machine_id: m.id,
        name: "x",
        value: 1.0,
        at: DateTime.add(now, -10 * 86_400)
      })

      Repo.insert!(%Dokkit.ProcessTop{
        machine_id: m.id,
        kind: "memory",
        at: DateTime.add(now, -5 * 3600),
        items: []
      })

      Repo.insert!(%Dokkit.MachineSlot{
        machine_id: m.id,
        slot: DateTime.truncate(DateTime.add(now, -10 * 86_400), :second)
      })

      Repo.insert!(%Machine{
        name: "v-seen",
        kind: :seen,
        last_seen_at: DateTime.add(now, -10 * 86_400)
      })

      Watch.prune(now)
      assert Repo.aggregate(Metric, :count) == 1
      assert Repo.aggregate(Dokkit.ProcessTop, :count) == 1
      assert Repo.aggregate(Dokkit.MachineSlot, :count) == 1
      assert Repo.get_by(Machine, name: "v-seen")

      set(%{"metrics_days" => 5, "processes_hours" => 2, "slots_days" => 5, "hosts_days" => 5})
      Watch.prune(now)
      assert Repo.aggregate(Metric, :count) == 0
      assert Repo.aggregate(Dokkit.ProcessTop, :count) == 0
      assert Repo.aggregate(Dokkit.MachineSlot, :count) == 0
      refute Repo.get_by(Machine, name: "v-seen")
    end

    test "the longest log line is a setting" do
      set(%{"longest_line_kb" => 1})
      row = Logs.row(%{"msg" => String.duplicate("a", 2000)}, nil, nil, DateTime.utc_now())
      assert byte_size(row.msg) == 1024
      assert row.cut
    end
  end

  describe "errors" do
    test "how many reports are kept in full is a setting" do
      s = service(machine("v-err"), "app")
      set(%{"errors_first" => 2, "errors_every" => 3})
      for _ <- 1..6, do: Errors.report(s, %{"type" => "Boom"})
      assert Repo.aggregate(Dokkit.ErrorEvent, :count) == 4
    end

    test "a burst of errors opens an issue at 10 by default, is a setting, and closes when calm" do
      s = service(machine("v-burst"), "app")
      for _ <- 1..9, do: Errors.report(s, %{"type" => "Boom"})
      assert Issues.open_list() == []
      Errors.report(s, %{"type" => "Boom"})
      assert [%{title: "app is raising errors"}] = Issues.open_list()

      quiet = service(machine("v-burst-off"), "app")
      set(%{"error_alert_on" => false})
      for _ <- 1..12, do: Errors.report(quiet, %{"type" => "Boom"})
      assert [_] = Issues.open_list()

      set(%{"error_alert_on" => false})
      Errors.calm()
      assert Issues.open_list() == []
    end
  end

  describe "alerts" do
    setup do
      test = self()

      Req.Test.stub(Alerts, fn conn ->
        send(test, {:sent, conn.host})
        Plug.Conn.send_resp(conn, Process.get(:status, 500), "{}")
      end)

      Alerts.save(%{"ntfy_url" => "https://ntfy.example/topic", "degraded" => "push"})
      s = service(machine("v-al"), "app")
      c = check(s, fail_after: 1)
      noon = %{DateTime.utc_now() | hour: 12, minute: 0}
      Issues.record(c, :degraded, at: noon, now: noon)
      %{issue: Repo.one!(from i in Issue, where: i.check_id == ^c.id)}
    end

    defp age(minutes),
      do:
        Repo.update_all(Alert, set: [updated_at: DateTime.add(DateTime.utc_now(), -minutes * 60)])

    test "a failed send is tried as many times as Settings says" do
      assert Alerts.deliver_pending() == 1
      age(2)
      assert Alerts.deliver_pending() == 1
      set(%{"send_tries" => 2})
      age(2)
      assert Alerts.deliver_pending() == 0
    end

    test "reminders are on every 30 minutes, can be switched off, and go on the channels told", %{
      issue: issue
    } do
      noon = %{DateTime.utc_now() | hour: 12, minute: 0}

      sent = fn minutes ->
        Repo.update_all(Alert,
          set: [status: :sent, updated_at: DateTime.add(noon, -minutes * 60)]
        )
      end

      sent.(20)
      assert Alerts.remind(noon) == 0
      set(%{"remind_on" => false})
      sent.(60)
      assert Alerts.remind(noon) == 0
      assert Alerts.remind(%{noon | hour: 23}) == 0
      set(%{"remind_on" => true})
      assert Alerts.remind(%{noon | hour: 23}) == 0
      assert Alerts.remind(noon) == 1

      assert [%{channel: "push", status: :pending}] =
               Repo.all(from a in Alert, where: a.issue_id == ^issue.id and a.status == :pending)

      assert Alerts.remind(noon) == 0
      Issues.acknowledge([issue.id])
      sent.(60)
      assert Alerts.remind(noon) == 0
    end

    test "an iMessage the Mac has not picked up fails after the wait set", %{issue: issue} do
      mac = machine("v-mac", os: "darwin")
      alert = Repo.insert!(%Alert{issue_id: issue.id, channel: "imessage", status: :sending})

      Repo.insert!(%Dokkit.WorkRun{
        machine_id: mac.id,
        alert_id: alert.id,
        name: "imessage",
        state: :queued,
        inserted_at: DateTime.add(DateTime.utc_now(), -200)
      })

      assert Alerts.settle() == 0
      set(%{"imessage_wait_seconds" => 120})
      assert Alerts.settle() == 1
    end

    test "how long a test stays open, and when to suggest the digest, are settings", %{
      issue: issue
    } do
      assert Alerts.test_stays() == 120
      set(%{"test_open_seconds" => 600})
      assert Alerts.test_stays() == 600

      Repo.update!(
        Ecto.Changeset.change(issue,
          count: 3,
          snoozed_until: DateTime.add(DateTime.utc_now(), 3600)
        )
      )

      assert Alerts.suggestions() == []
      set(%{"suggest_count" => 3})
      assert [_] = Alerts.suggestions()
    end

    test "the snooze lengths on the inbox are a setting", %{conn: conn} do
      set(%{"snooze_choices" => "30m, 2d"})
      {:ok, _, html} = live(signed_in(conn), "/")
      assert html =~ ~s(value="1800")
      assert html =~ "2 days"
      refute html =~ "1 week"
    end
  end

  describe "the server" do
    test "a sign-in lasts as many days as Settings says", %{conn: conn} do
      user = Repo.insert!(%Dokkit.User{name: "v-old", password_hash: "-", role: :owner})
      old = Dokkit.Accounts.stamp() - 20 * 86_400 * 1_000_000

      session = fn c ->
        Plug.Test.init_test_session(c, %{"user_id" => user.id, "signed_at" => old})
      end

      assert get(session.(conn), "/settings").status == 302
      set(%{"session_days" => 30})
      assert get(session.(build_conn()), "/settings").status == 200
    end

    test "sign-in limits are settings" do
      set(%{"login_pair" => 2})
      ip = {10, 9, 8, 7}
      assert Dokkit.LoginThrottle.attempt("v-name", ip) == :ok
      assert Dokkit.LoginThrottle.attempt("v-name", ip) == :ok
      assert Dokkit.LoginThrottle.attempt("v-name", ip) == :blocked
    end

    test "enrolment codes last and are capped as Settings says" do
      set(%{"enrol_hours" => 2, "enrol_max_hours" => 6})
      {_, key} = Keys.mint_enrol("pc")
      assert DateTime.diff(key.expires_at, DateTime.utc_now()) in 7100..7200
      assert Keys.enrol_most_hours() == 6
    end

    test "nothing reporting alarms after the minutes set" do
      now = DateTime.utc_now()
      machine("v-loft", last_seen_at: DateTime.add(now, -1200))
      set(%{"self_quiet_minutes" => 30})
      Dokkit.Self.tick(now, %{})
      assert %{state: :ok} = Repo.get_by!(Service, slug: "dokkit")
    end

    test "an update fails after the minutes set" do
      now = DateTime.utc_now()

      m =
        machine("v-upd",
          program_version: "v1",
          wanted_version: "v2",
          update_started_at: DateTime.add(now, -55 * 60)
        )

      assert {:failed, "did not report back within 50 minutes"} = Dokkit.UpdateRun.status(m, now)
      set(%{"update_run_minutes" => 60})
      assert {:waiting, nil} = Dokkit.UpdateRun.status(m, now)
    end
  end

  describe "the API and the pages" do
    test "settings are read and changed through the API with the scopes the pages need" do
      m = machine("v-api")
      {read, _} = Keys.mint(:user, %{scopes: ["read"]})
      {act, _} = Keys.mint(:user, %{scopes: ["act"]})
      {admin, _} = Keys.mint(:user, %{scopes: ["admin"]})
      as = fn token -> put_req_header(build_conn(), "authorization", "Bearer " <> token) end

      assert %{"values" => %{"session_days" => 14}} =
               as.(read) |> get("/api/v1/settings") |> json_response(200)

      assert as.(act) |> put("/api/v1/settings", %{"session_days" => 3}) |> json_response(403)

      assert %{"values" => %{"session_days" => 3}, "changed" => ["session_days"]} =
               as.(admin) |> put("/api/v1/settings", %{"session_days" => 3}) |> json_response(200)

      assert %{"error" => %{"code" => "bad_settings"}} =
               as.(admin) |> put("/api/v1/settings", %{"session_days" => 0}) |> json_response(422)

      assert as.(act)
             |> put("/api/v1/machines/#{m.id}/settings", %{"silent_minutes" => 9})
             |> json_response(403)

      assert %{"values" => %{"silent_minutes" => 9}} =
               as.(admin)
               |> put("/api/v1/machines/#{m.id}/settings", %{"silent_minutes" => 9})
               |> json_response(200)

      assert %{"defaults" => %{"silent_minutes" => 3}} =
               as.(read) |> get("/api/v1/machines/#{m.id}/settings") |> json_response(200)

      assert as.(admin) |> put("/api/v1/machines/nope/settings", %{}) |> json_response(404)

      {s, _} = job("v-api-job", %{})

      assert as.(act)
             |> put("/api/v1/jobs/#{s.id}/settings", %{"job_missed" => false})
             |> json_response(403)

      assert %{"values" => %{"job_missed" => false}} =
               as.(admin)
               |> put("/api/v1/jobs/#{s.id}/settings", %{"job_missed" => false})
               |> json_response(200)
    end

    test "a member sees a machine's and a job's settings but cannot change them", %{conn: conn} do
      member = Repo.insert!(%Dokkit.User{name: "v-member", password_hash: "-", role: :member})

      conn =
        Plug.Test.init_test_session(conn, %{
          "user_id" => member.id,
          "signed_at" => Dokkit.Accounts.stamp()
        })

      m = machine("v-member-m")
      {:ok, view, html} = live(conn, "/machines/#{m.id}")
      assert html =~ "Settings for v-member-m"

      render_submit(view, "values_save", %{
        "group" => "machines",
        "values" => %{"silent_minutes" => "9"}
      })

      assert Values.own({:machine, m.id}) == %{}
    end

    test "Settings, a machine's page and Jobs show the folds, save and reset", %{conn: conn} do
      conn = signed_in(conn)
      {:ok, view, html} = live(conn, "/settings")
      assert html =~ "Defaults for every machine"
      assert html =~ "Default: On, every 30 minutes"
      assert html =~ "Default: On, slow at 90% for 10 minutes"
      assert html =~ "Default: On, when 10 errors arrive within 15 minutes"

      html =
        view |> form("#set-alerts-form", %{"values" => %{"send_tries" => "3"}}) |> render_submit()

      assert html =~ "1 setting differs from the default."
      assert Values.get("send_tries") == 3
      html = view |> element("#set-alerts-tries button", "Reset") |> render_click()
      assert html =~ "Back to the default."
      assert Values.get("send_tries") == 5

      m = machine("v-page")
      {:ok, view, html} = live(conn, "/machines/#{m.id}")
      assert html =~ "Settings for v-page"

      view
      |> form("#machine-values-form", %{"values" => %{"silent_minutes" => "7"}})
      |> render_submit()

      assert Values.get("silent_minutes", {:machine, m.id}) == 7

      {s, _} = job("v-page-job", %{})
      {:ok, view, html} = live(conn, "/jobs")
      assert html =~ "Settings for"

      view
      |> form("#job-#{s.id}-form", %{"values" => %{"job_keep_days" => "5"}})
      |> render_submit()

      assert Values.get("job_keep_days", {:job, s.id}) == 5
    end

    test "a machine's unsaved settings survive the page reloading when the machine reports",
         %{conn: conn} do
      m = machine("v-sql")
      {:ok, view, _} = live(signed_in(conn), "/machines/#{m.id}?tab=alerts")

      view
      |> form("#machine-values-form", %{"values" => %{"memory_on" => "false"}})
      |> render_change()

      view
      |> form("#silent-form", %{"silent" => %{"down" => ["email"], "night" => "false"}})
      |> render_change()

      Repo.update!(Ecto.Changeset.change(m, last_seen_at: DateTime.utc_now()))
      send(view.pid, :issues_changed)

      refute has_element?(view, ~s(#machine-values input[name="values[memory_on]"][checked]))
      assert has_element?(view, ~s(#silent-form input[value="email"][checked]))
      refute has_element?(view, ~s(#silent-form input[name="silent[night]"][checked]))

      view |> form("#machine-values-form") |> render_submit()
      assert Values.get("memory_on", {:machine, m.id}) == false
      refute has_element?(view, ~s(#machine-values input[name="values[memory_on]"][checked]))
    end

    test "the public demo turns every settings save and reset off" do
      for view <- [DokkitWeb.SettingsLive, DokkitWeb.MachineLive, DokkitWeb.JobsLive],
          event <- ~w(values_save values_reset),
          do: assert(DokkitWeb.DemoSeat.off?(view, event))
    end
  end

  describe "review fixes" do
    test "values are read through a cache that a save empties" do
      old = Application.get_env(:dokkit, :values_cache_ms)
      Application.put_env(:dokkit, :values_cache_ms, 60_000)
      on_exit(fn -> Application.put_env(:dokkit, :values_cache_ms, old) end)
      Values.forget()

      assert Values.get("send_tries") == 5
      Dokkit.Setting.put("values", %{"send_tries" => 9})
      assert Values.get("send_tries") == 5
      set(%{"send_tries" => 7})
      assert Values.get("send_tries") == 7
      Values.forget()
    end

    test "a limit stored with a fraction stays as it is" do
      Alerts.save(%{"disk_limit" => "87.5"})
      assert Values.get("disk_limit") == 87.5
      assert Values.view(:server)["values"]["disk_limit"] == 87.5
    end

    test "a stored value that breaks a pair blocks only saves of that pair" do
      Alerts.save(%{"disk_limit" => "99"})
      set(%{"send_tries" => 3})

      assert {:error, "disk_down is at or above disk_limit."} =
               Values.save(:server, %{"disk_down" => 97})

      assert {:error, _} = Alerts.update(%{"disk_limit" => "150"})
      assert {:ok, _, _} = Alerts.update(%{"disk_limit" => ""})
    end

    test "going quiet is longer than two reports, and the server waits for the updater" do
      assert {:error, "silent_minutes is at least" <> _} =
               Values.save(:server, %{"silent_minutes" => 2})

      assert {:error, "silent_minutes is at least" <> _} =
               Values.save(:server, %{"report_seconds" => 600})

      set(%{"report_seconds" => 30, "silent_minutes" => 2})

      assert {:error, "update_run_minutes is at least updater_minutes" <> _} =
               Values.save(:server, %{"update_run_minutes" => 30})

      set(%{"updater_minutes" => 20, "update_run_minutes" => 25})
    end

    test "a max_runtime that cannot be read is still flagged after an hour" do
      {_, c} = job("v-job-bad", %{"max_runtime" => "soon"})
      started = DateTime.add(DateTime.utc_now(), -90 * 60)
      Repo.insert!(%JobRun{check_id: c.id, run: "r", result: :running, started_at: started})
      assert Watch.sweep() == 1
    end

    test "a burst writes once, closes only its own check, and a declare keeps it" do
      m = machine("v-burst2")
      {mkey, _} = Keys.mint(:machine, %{machine_id: m.id})
      s = service(m, "app")
      mine = check(s, name: "errors", state: :down, fail_after: 1)
      set(%{"error_alert_on" => true, "error_alert_count" => 2})

      for _ <- 1..2, do: Errors.report(s, %{"type" => "Boom"})
      burst = Repo.get_by!(Check, name: "errors.burst")
      at = burst.checked_at
      for _ <- 1..5, do: Errors.report(s, %{"type" => "Boom"})
      assert Repo.reload!(burst).checked_at == at

      put_req_header(build_conn(), "authorization", "Bearer " <> mkey)
      |> put("/api/v1/declare", %{schema: 1, service: %{id: "app", name: "app"}, check: []})
      |> json_response(200)

      assert Repo.reload(burst)
      set(%{"error_alert_on" => false})
      Errors.calm()
      assert Repo.reload!(burst).state == :ok
      assert Repo.reload!(mine).state == :down
    end

    test "enrolment codes are capped at the most, and a limit with no machine does not raise" do
      set(%{"enrol_hours" => 2, "enrol_max_hours" => 3})
      {_, key} = Keys.mint_enrol("pc", 24 * 3600)
      assert DateTime.diff(key.expires_at, DateTime.utc_now()) in (3 * 3600 - 60)..(3 * 3600)

      check = %Check{config: %{"limit_from" => "disk_limit"}, service: %Service{machine_id: nil}}
      assert Numbers.limit(check) == 90.0
    end
  end
end
