defmodule Dokkit.SoonTest do
  use DokkitWeb.ConnCase, async: true
  import Ecto.Query
  alias Dokkit.{Check, Issue, Issues, JobRun, Keys, Machine, Numbers, Repo, Service, Watch}

  defp titles, do: Enum.map(Repo.all(from i in Issue, where: is_nil(i.closed_at)), & &1.title)

  defp disk(machine, name, values) do
    now = DateTime.utc_now()
    n = length(values)

    for {v, i} <- Enum.with_index(values),
        do: Numbers.record(machine.id, nil, name, v, DateTime.add(now, -(n - 1 - i) * 86_400))

    now
  end

  test "a disk heading for its limit is soon, and closes when the line flattens" do
    m = Repo.insert!(%Machine{name: "soon-a", kind: :enrolled})
    name = "disk.used_percent.D"
    now = disk(m, name, [60, 62, 64, 66, 68, 70, 72, 74])
    Numbers.forecast(now)
    assert "Disk D on soon-a fills in about 8 days" in titles()
    assert %{soon: true} = Repo.get_by!(Issue, title: "Disk D on soon-a fills in about 8 days")

    # Running it again changes nothing.
    Numbers.forecast(now)
    assert Enum.count(titles(), &(&1 =~ "soon-a")) == 1

    Repo.delete_all(from x in Dokkit.Metric, where: x.machine_id == ^m.id)
    now = disk(m, name, List.duplicate(74, 8))
    Numbers.forecast(now)
    refute Enum.any?(titles(), &(&1 =~ "soon-a"))
  end

  test "a disk far from its limit, or with too little data, is left alone" do
    m = Repo.insert!(%Machine{name: "soon-b", kind: :enrolled})
    now = disk(m, "disk.used_percent.C", [10, 11, 12, 13, 14, 15, 16, 17])
    Numbers.forecast(now)
    m2 = Repo.insert!(%Machine{name: "soon-c", kind: :enrolled})
    now = disk(m2, "disk.used_percent.C", [80, 88])
    Numbers.forecast(now)
    refute Enum.any?(titles(), &(&1 =~ "soon-"))
  end

  test "a disk over its limit has no forecast issue and says when it will be full" do
    m = Repo.insert!(%Machine{name: "soon-d", kind: :enrolled})
    name = "disk.used_percent.E"
    now = disk(m, name, [80, 82, 84, 86, 88, 90, 92, 94])
    Numbers.forecast(now)
    refute Enum.any?(titles(), &(&1 =~ "fills in"))

    for _ <- 1..3, do: Numbers.record(m.id, nil, name, 94, DateTime.utc_now())

    assert [%{state: :down, soon: false} = issue] =
             Repo.all(from i in Issue, where: i.machine_id == ^m.id)

    assert issue.title == "Disk E is nearly full"
    Numbers.forecast(DateTime.utc_now())
    Numbers.record(m.id, nil, name, 94, DateTime.utc_now())
    check = Repo.get!(Check, issue.check_id)
    assert check.note =~ "At this week's rate it is full in about"
  end

  defp job(slug, config) do
    m = Repo.insert!(%Machine{name: "soon-" <> slug, kind: :enrolled})
    s = Repo.insert!(%Service{machine_id: m.id, slug: slug, name: "Job " <> slug, kind: :job})

    c =
      Repo.insert!(%Check{
        service_id: s.id,
        name: slug,
        type: :job,
        fail_after: 1,
        config: config
      })

    {key, _} = Keys.mint(:machine, %{machine_id: m.id})
    {key, s, %{c | service: s}}
  end

  test "a run that finishes over its max_runtime is soon, and the next good one closes it" do
    {key, _, c} = job("nightly", %{"max_runtime" => "1m"})

    line = fn run, ms ->
      %{type: "job", service: "nightly", name: "nightly", event: "ok", run: run, duration_ms: ms}
    end

    report(key, [line.("a", 120_000)])

    assert [%{title: "Job nightly ran long", soon: true}] =
             Repo.all(from i in Issue, where: i.check_id == ^c.id)

    assert Repo.get!(Check, c.id).note == "It took 2 min 0 s. The limit is 1m."

    report(key, [line.("b", 90_000)])
    assert Repo.get!(Check, c.id).note =~ "That is 2 times in the last 7 days."

    report(key, [line.("c", 10_000)])
    assert Repo.all(from i in Issue, where: i.check_id == ^c.id and is_nil(i.closed_at)) == []
    assert Issues.open_list() |> Enum.all?(&(&1.check_id != c.id))
  end

  test "a job that did not run says when it last ran well" do
    now = %{DateTime.utc_now() | second: 45, microsecond: {0, 6}}
    {_, _, c} = job("late", %{"schedule" => "* * * * *", "grace" => "30s"})

    Repo.update_all(from(k in Check, where: k.id == ^c.id),
      set: [inserted_at: DateTime.add(now, -3 * 3600)]
    )

    Repo.insert!(%JobRun{
      check_id: c.id,
      run: "x",
      result: :ok,
      started_at: DateTime.add(now, -7200),
      finished_at: DateTime.add(now, -7200),
      duration_ms: 30_000
    })

    assert Watch.sweep(now) >= 1
    note = Repo.get!(Check, c.id).note
    assert note =~ "Expected at"
    assert note =~ "Its last good run was"
    assert note =~ "and took 30 s."
  end
end
