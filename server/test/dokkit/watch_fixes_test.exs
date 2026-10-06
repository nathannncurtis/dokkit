defmodule Dokkit.WatchFixesTest do
  use Dokkit.DataCase, async: true
  import Ecto.Query
  alias Dokkit.{Alert, Check, Estate, Issue, Issues, JobRun, Machine, Repo, Service, Watch}

  defp job(machine, slug, config, kind \\ :enrolled) do
    m = Repo.insert!(%Machine{name: machine, kind: kind, last_seen_at: DateTime.utc_now()})
    s = Repo.insert!(%Service{machine_id: m.id, slug: slug, name: slug, kind: :job})

    c =
      Repo.insert!(%Check{
        service_id: s.id,
        name: slug,
        type: :job,
        fail_after: 1,
        config: config
      })

    {m, s, %{c | service: s}}
  end

  test "a schedule that cannot be read does not stop the sweep" do
    {_, _, _} = job("wf-a", "reboot", %{"schedule" => "@reboot"})
    {_, _, _} = job("wf-b", "numeric", %{"schedule" => 5})
    assert is_integer(Watch.sweep())

    assert {:error, _} =
             Estate.add_job(%{"name" => "Boot", "machine" => "wf-c", "schedule" => "@reboot"})

    assert Estate.next_expected(%Check{config: %{"schedule" => "@reboot"}}) == nil
  end

  test "a run a little ahead of the due time counts, and an old running run does not stay overdue" do
    now = ~U[2026-10-06 01:00:40.000000Z]
    cfg = %{"schedule" => "* * * * *", "grace" => "30s", "max_runtime" => "1m"}
    {_, _, c} = job("wf-d", "ontime", cfg)
    {_, _, c2} = job("wf-d2", "late", cfg)

    for x <- [c, c2],
        do:
          Repo.update_all(from(k in Check, where: k.id == ^x.id),
            set: [inserted_at: ~U[2026-10-06 00:00:00.000000Z]]
          )

    Repo.insert!(%JobRun{
      check_id: c.id,
      run: "old",
      result: :running,
      started_at: ~U[2026-10-05 22:00:00.000000Z]
    })

    for {x, at} <- [{c, ~U[2026-10-06 00:59:30.000000Z]}, {c2, ~U[2026-10-06 00:58:30.000000Z]}] do
      Repo.insert!(%JobRun{
        check_id: x.id,
        run: "new",
        result: :ok,
        started_at: at,
        finished_at: at
      })
    end

    assert Watch.sweep(now) == 1
    assert %{state: :down} = Repo.get!(Service, c2.service_id)
    assert %{state: s} = Repo.get!(Service, c.service_id)
    refute s == :down
  end

  test "an outage is not quiet time for beats or jobs" do
    now = DateTime.utc_now()
    booted = DateTime.add(now, -180)
    m = Repo.insert!(%Machine{name: "wf-k", kind: :seen})
    s = Repo.insert!(%Service{machine_id: m.id, slug: "wfk", name: "wfk"})

    b =
      Repo.insert!(%Check{
        service_id: s.id,
        name: "loop",
        type: :beat,
        fail_after: 1,
        config: %{"every_seconds" => 300},
        checked_at: DateTime.add(now, -850)
      })

    assert Watch.sweep(now, booted) == 0
    assert Watch.sweep(now) == 1
    assert Repo.get!(Check, b.id).state == :down
  end

  test "settling after boot, and pruning" do
    now = DateTime.utc_now()
    refute Watch.settled?(DateTime.add(now, -60), now)
    assert Watch.settled?(DateTime.add(now, -200), now)

    {m, _, _} = job("wf-e", "gone", %{}, :seen)

    Repo.update_all(from(x in Machine, where: x.id == ^m.id),
      set: [last_seen_at: DateTime.add(now, -40 * 86_400)]
    )

    {m2, _, _} = job("wf-f", "kept", %{}, :seen)

    lone =
      Repo.insert!(%Machine{
        name: "wf-g",
        kind: :seen,
        last_seen_at: DateTime.add(now, -40 * 86_400)
      })

    {_, key} = Dokkit.Keys.mint(:machine, %{machine_id: m2.id})

    old =
      Repo.insert!(%Dokkit.Batch{
        key_id: key.id,
        accepted: 1,
        inserted_at: DateTime.add(now, -25 * 3600)
      })

    fresh = Repo.insert!(%Dokkit.Batch{key_id: key.id, accepted: 1, inserted_at: now})

    Watch.prune(now)
    assert Repo.get(Dokkit.Batch, old.id) == nil
    assert Repo.get(Dokkit.Batch, fresh.id)
    assert Repo.get(Machine, lone.id) == nil
    assert Repo.get(Machine, m.id)
    assert Repo.get(Machine, m2.id)
  end

  test "an issue held back while the machine was down is alerted when it returns" do
    now = DateTime.utc_now()
    {m, s, c} = job("wf-h", "held", %{})
    Dokkit.Alerts.save(%{"down" => "push"})
    Repo.update_all(from(x in Service, where: x.id == ^s.id), set: [route_down: "push"])

    Repo.update_all(from(x in Machine, where: x.id == ^m.id),
      set: [last_seen_at: DateTime.add(now, -600)]
    )

    Issues.machines_sweep(now)
    Issues.record(c, :down, at: now)
    assert Repo.aggregate(Alert, :count) >= 0
    issue = Repo.get_by!(Issue, check_id: c.id)
    assert Repo.all(from a in Alert, where: a.issue_id == ^issue.id) == []
    Repo.update_all(from(x in Machine, where: x.id == ^m.id), set: [last_seen_at: now])
    Issues.machines_sweep(now)
    assert [_] = Repo.all(from a in Alert, where: a.issue_id == ^issue.id)
  end

  test "a returning machine alerts only what opened during the outage and is not acknowledged" do
    now = DateTime.utc_now()
    {m, s, c} = job("wf-l", "before", %{})
    Repo.update_all(from(x in Service, where: x.id == ^s.id), set: [route_down: "none"])
    Issues.record(c, :down, at: DateTime.add(now, -3600))
    Dokkit.Alerts.save(%{"down" => "push"})
    Repo.update_all(from(x in Service, where: x.id == ^s.id), set: [route_down: "push"])

    c2 = Repo.insert!(%Check{service_id: s.id, name: "during", type: :custom, fail_after: 1})

    Repo.update_all(from(x in Machine, where: x.id == ^m.id),
      set: [last_seen_at: DateTime.add(now, -600)]
    )

    Issues.machines_sweep(now)
    Issues.record(c2, :down, at: now)
    Repo.update_all(from(x in Machine, where: x.id == ^m.id), set: [last_seen_at: now])
    Issues.machines_sweep(now)

    before = Repo.get_by!(Issue, check_id: c.id)
    during = Repo.get_by!(Issue, check_id: c2.id)
    assert Repo.all(from a in Alert, where: a.issue_id == ^before.id) == []
    assert [_] = Repo.all(from a in Alert, where: a.issue_id == ^during.id)
  end

  test "declare refuses a bad fail_after and keeps the name of a process check" do
    m = Repo.insert!(%Machine{name: "wf-n", kind: :enrolled})

    doc = %{
      "schema" => 1,
      "service" => %{"id" => "wfn"},
      "check" => [%{"type" => "process", "name" => "nginx", "fail_after" => 3_000_000_000}]
    }

    assert {:error, _} = Estate.declare(m.id, doc)

    assert {:error, _} =
             Estate.declare(m.id, put_in(doc["check"], [%{"type" => "tcp", "fail_after" => 0}]))

    assert {:ok, svc} =
             Estate.declare(
               m.id,
               put_in(doc["check"], [%{"type" => "process", "name" => "nginx"}])
             )

    assert %{config: %{"name" => "nginx"}} =
             Repo.get_by!(Check, service_id: svc.id, name: "process")
  end

  test "declare refuses a bad schedule, names process checks by type, and drops checks cleanly" do
    m = Repo.insert!(%Machine{name: "wf-i", kind: :enrolled})

    doc = %{
      "schema" => 1,
      "service" => %{"id" => "wfsvc"},
      "job" => [%{"id" => "j", "schedule" => "@reboot"}]
    }

    assert {:error, _} = Estate.declare(m.id, doc)

    doc = %{
      "schema" => 1,
      "service" => %{"id" => "wfsvc"},
      "check" => [
        %{"type" => "process", "name" => "nginx"},
        %{"type" => "tcp", "port" => 1, "fail_after" => 1},
        %{"type" => "tcp", "name" => "tcp-2", "port" => 2}
      ]
    }

    assert {:ok, svc} = Estate.declare(m.id, doc)
    names = Repo.all(from c in Check, where: c.service_id == ^svc.id, select: c.name)
    assert Enum.sort(names) == ["process", "tcp", "tcp-2"]

    check = Repo.get_by!(Check, service_id: svc.id, name: "tcp")
    Issues.record(check, :down, at: DateTime.utc_now())
    assert %{state: :down} = Repo.get!(Service, svc.id)
    assert {:ok, _} = Estate.declare(m.id, put_in(doc["check"], [%{"type" => "process"}]))
    assert %{state: :unknown} = Repo.get!(Service, svc.id)
    assert [%{closed_at: %DateTime{}}] = Repo.all(from i in Issue, where: i.service_id == ^svc.id)
  end
end
