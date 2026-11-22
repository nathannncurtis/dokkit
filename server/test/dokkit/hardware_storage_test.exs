defmodule Dokkit.HardwareStorageTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Dokkit.{Issues, Keys, Machine, Repo, Values}

  defp machine(name) do
    m = Repo.insert!(%Machine{name: name, kind: :enrolled})
    {key, _} = Keys.mint(:machine, %{machine_id: m.id})
    {m, key}
  end

  defp open_on(m), do: Enum.filter(Issues.open_list(), &(&1.machine_id == m.id))

  defp state(check, state, note \\ nil),
    do: %{type: "state", check: check, state: state, note: note}

  defp times(line, n), do: for(_ <- 1..n, do: line)

  test "an array short of a drive opens down after 3 reports, rebuilding is degraded, and fine closes it" do
    {m, key} = machine("nas-01")
    lost = state("hw.array.md1", "down", "1 of 4 drives missing")

    report(key, times(lost, 2))
    assert open_on(m) == []

    report(key, [lost])

    assert [%{title: "Array md1 is down on nas-01", state: :down, service: %{slug: "machine"}}] =
             open_on(m)

    report(key, times(state("hw.array.md1", "degraded", "Rebuilding, 41.2% done"), 3))
    assert [%{title: "Array md1 needs a look on nas-01", state: :degraded}] = open_on(m)

    report(key, times(state("hw.array.md1", "ok"), 3))
    assert open_on(m) == []
  end

  test "a failing drive opens with a sentence for its title" do
    {m, key} = machine("web-01")
    report(key, times(state("hw.smart.disk0", "down", "SMART status: Failing"), 3))
    assert [%{title: "Drive disk0 is failing on web-01", state: :down}] = open_on(m)
  end

  test "a machine's own reports in a row and switch replace the defaults" do
    {m, key} = machine("nas-02")
    {:ok, _} = Values.save({:machine, m.id}, %{"array_after" => 1, "smart_on" => false})

    report(key, [state("hw.array.vol1", "down", "The NAS says the volume is Degraded")])
    assert [%{title: "Array vol1 is down on nas-02"}] = open_on(m)

    report(key, times(state("hw.smart.hd3", "down", "The NAS says the drive is Abnormal"), 3))
    assert [%{title: "Array vol1 is down on nas-02"}] = open_on(m)
  end

  test "arrays and drive health settings default on, save and reset for a machine" do
    {m, _} = machine("nas-03")
    scope = {:machine, m.id}

    for {k, v} <- [{"array_on", true}, {"array_after", 3}, {"smart_on", true}, {"smart_after", 3}],
        do: assert(Values.default(k) == v, k)

    {:ok, view} = Values.save(scope, %{"array_after" => 1})
    assert "array_after" in view["changed"]
    {:ok, view} = Values.reset(scope, "array")
    assert view["changed"] == []
    assert Values.get("array_after", scope) == 3
  end

  test "the machine page shows arrays with their setting and a muted line for no drives",
       %{conn: conn} do
    {m, key} = machine("nas-04")
    report(key, [state("hw.array.md3", "ok", "Checking, 30.0% done")])

    {:ok, view, html} = live(signed_in(conn), "/machines/#{m.id}")
    assert html =~ "Array md3"
    assert html =~ "Checking, 30.0% done"
    assert has_element?(view, "#hw-arrays-form")
    assert has_element?(view, "#hw-drives-none")
    refute has_element?(view, "#hw-drives-form")

    view |> form("#hw-arrays-form", %{"values" => %{"array_after" => "2"}}) |> render_submit()
    assert Values.get("array_after", {:machine, m.id}) == 2
  end
end
