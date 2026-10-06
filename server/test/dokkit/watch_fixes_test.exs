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
    now = DateTime.utc_now()

    {_, _, c} =
      job("wf-d", "ontime", %{"schedule" => "* * * * *", "grace" => "1s", "max_runtime" => "1m"})

    c = %{c | inserted_at: DateTime.add(now, -3600)}
    Repo.update_all(from(x in Check, where: x.id == ^c.id), set: [inserted_at: c.inserted_at])

    Repo.insert!(%JobRun{
      check_id: c.id,
      run: "old",
      result: :running,
      started_at: DateTime.add(now, -7200)
    })

    Repo.insert!(%JobRun{
      check_id: c.id,
      run: "new",
      result: :ok,
      started_at: DateTime.add(now, -5),
      finished_at: now
    })

    assert Watch.sweep(DateTime.add(now, 5)) == 0
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

    Watch.prune(now)
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
