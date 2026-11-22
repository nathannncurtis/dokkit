defmodule Dokkit.UpsTest do
  use DokkitWeb.ConnCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest
  alias Dokkit.{Issue, Issues, Keys, Machine, Repo, Values}

  defp machine(name) do
    m = Repo.insert!(%Machine{name: name, kind: :enrolled})
    {key, _} = Keys.mint(:machine, %{machine_id: m.id})
    {m, key}
  end

  defp at(start, seconds), do: DateTime.to_iso8601(DateTime.add(start, seconds))
  defp open_on(m), do: Enum.filter(Issues.open_list(), &(&1.machine_id == m.id))
  defp ago(hours \\ 1), do: DateTime.add(DateTime.utc_now(), -hours * 3600)

  defp power(state, charge, t, s),
    do: %{type: "state", check: "hw.ups.power", state: state, value: charge, at: at(t, s)}

  defp battery(state, charge, t, s, note \\ nil),
    do: %{
      type: "state",
      check: "hw.ups.battery",
      state: state,
      value: charge,
      note: note,
      at: at(t, s)
    }

  defp metric(name, value, t, s), do: %{type: "metric", name: name, value: value, at: at(t, s)}

  test "a power cut opens at once as down, and closes after two minutes on mains with its length and lowest charge" do
    {m, key} = machine("ups-01")
    t = ago()

    report(key, [power("down", 90, t, 0)])

    assert [%{title: "Power is out at ups-01", state: :down, service: %{slug: "machine"}}] =
             open_on(m)

    report(key, [power("down", 80, t, 60)])
    report(key, [power("ok", 85, t, 120)])
    report(key, [power("ok", 86, t, 180)])
    assert [%{title: "Power is out at ups-01"}] = open_on(m)

    report(key, [power("ok", 88, t, 240)])
    assert open_on(m) == []

    [issue] = Repo.all(from i in Issue, where: i.machine_id == ^m.id)
    assert [%{"text" => "Power was out for 2 minutes. The lowest charge was 80%."}] = issue.notes
  end

  test "a cut that ends inside the two minutes and starts again stays one issue" do
    {m, key} = machine("ups-02")
    t = ago()
    report(key, [power("down", 90, t, 0), power("ok", 90, t, 60), power("down", 70, t, 120)])
    report(key, for(s <- [180, 240, 300], do: power("ok", 75, t, s)))
    assert [issue] = Repo.all(from i in Issue, where: i.machine_id == ^m.id)
    assert issue.closed_at
    assert [%{"text" => "Power was out for 3 minutes. The lowest charge was 70%."}] = issue.notes
  end

  test "a battery running low during a cut is degraded beside the cut" do
    {m, key} = machine("ups-03")
    t = ago()

    report(key, [
      metric("ups.runtime_minutes", 6, t, 0),
      power("down", 50, t, 0),
      battery("ok", 50, t, 0)
    ])

    titles = m |> open_on() |> Enum.map(&{&1.title, &1.state}) |> Enum.sort()

    assert titles == [
             {"Power is out at ups-03", :down},
             {"The UPS battery is running low at ups-03", :degraded}
           ]

    [b] = Enum.filter(open_on(m), &(&1.check.name == "hw.ups.battery"))
    assert b.check.note == "About 6 minutes of battery left."
  end

  test "a replace flag or failed self-test on mains is degraded with the UPS's words" do
    {m, key} = machine("ups-04")
    t = ago()
    note = "The UPS says its battery needs replacing"
    report(key, [power("ok", 100, t, 0), battery("degraded", 100, t, 0, note)])

    assert [%{title: "The UPS battery needs a look at ups-04", state: :degraded} = i] = open_on(m)
    assert i.check.note == note <> "."

    report(key, [battery("ok", 100, t, 60)])
    assert open_on(m) == []
  end

  test "a battery that does not charge back up within a day on mains is degraded" do
    {m, key} = machine("ups-05")
    t = ago(30)
    report(key, [power("ok", 60, t, 0), battery("ok", 60, t, 0)])
    assert open_on(m) == []

    report(key, [battery("ok", 70, t, 25 * 3600)])

    assert [%{title: "The UPS battery needs a look at ups-05"} = i] = open_on(m)
    assert i.check.note == "The battery is charged to only 70% after 24 hours on mains."
  end

  test "a UPS's load opens after its minutes" do
    {m, key} = machine("ups-06")
    t = ago()
    report(key, for(s <- [0, 60, 120], do: metric("ups.load_percent", 85, t, s)))
    assert [%{title: "UPS load at 85% on ups-06", state: :degraded}] = open_on(m)
  end

  test "switched off, a cut opens nothing" do
    {m, key} = machine("ups-07")
    {:ok, _} = Values.save({:machine, m.id}, %{"ups_power_on" => false})
    report(key, [power("down", 90, ago(), 0)])
    assert open_on(m) == []
  end

  test "a restart without a shutdown is open for its hours and then closes" do
    {m, key} = machine("web-11")
    boot = DateTime.add(DateTime.utc_now(), -600)

    line = %{
      type: "state",
      check: "hw.restart",
      state: "degraded",
      value: DateTime.to_unix(boot),
      note: "Started after stopping without a shutdown"
    }

    report(key, [line])
    assert [%{title: "web-11 restarted without shutting down", state: :degraded} = i] = open_on(m)
    assert i.check.note =~ "It started again at #{Calendar.strftime(boot, "%Y-%m-%d %H:%M")} UTC"

    {:ok, _} = Values.save({:machine, m.id}, %{"restart_hours" => 1})
    report(key, [%{line | value: DateTime.to_unix(boot) - 3600}])
    assert open_on(m) == []

    report(key, [%{line | state: "ok"}])
    assert open_on(m) == []
  end

  test "UPS settings have their defaults, save and reset for a machine" do
    {m, _} = machine("ups-08")
    scope = {:machine, m.id}

    for {k, v} <- [
          {"ups_power_on", true},
          {"ups_power_minutes", 2},
          {"ups_battery_on", true},
          {"ups_runtime_limit", 10},
          {"ups_charge_limit", 30},
          {"ups_charge_mains", 80},
          {"ups_charge_hours", 24},
          {"ups_load_on", true},
          {"ups_load_limit", 80},
          {"ups_load_minutes", 3},
          {"restart_on", true},
          {"restart_hours", 24}
        ],
        do: assert(Values.default(k) == v, k)

    {:ok, _} = Values.save(scope, %{"ups_runtime_limit" => 15})
    assert Values.get("ups_runtime_limit", scope) == 15
    {:ok, view} = Values.reset(scope, "ups_battery")
    assert view["changed"] == []
    assert Values.get("ups_runtime_limit", scope) == 10
  end

  test "the machine page has a UPS row with its limits, and one muted line without a UPS", %{
    conn: conn
  } do
    {m, key} = machine("ups-09")
    t = ago()
    report(key, [metric("ups.charge_percent", 64, t, 0), power("down", 64, t, 0)])

    {:ok, view, html} = live(signed_in(conn), "/machines/#{m.id}")
    assert html =~ "UPS charge"
    assert html =~ "64%"
    assert render(element(view, "#hw-chart-ups\\.charge_percent")) =~ "On battery for"
    assert has_element?(view, "#hw-ups-form")

    view |> form("#hw-ups-form", %{"values" => %{"ups_load_limit" => "70"}}) |> render_submit()
    assert Values.get("ups_load_limit", {:machine, m.id}) == 70

    {other, _} = machine("ups-10")
    {:ok, view, _} = live(signed_in(conn), "/machines/#{other.id}")
    assert has_element?(view, "#hw-ups-none")
  end
end
