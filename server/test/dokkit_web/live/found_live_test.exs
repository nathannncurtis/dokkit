defmodule DokkitWeb.FoundLiveTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Dokkit.{Finding, Machine, Repo}

  setup %{conn: conn}, do: %{conn: signed_in(conn)}

  defp machine(name, os \\ "linux"),
    do: Repo.insert!(%Machine{name: name, kind: :enrolled, os: os})

  defp finding(m, kind, key, origin, extra \\ %{}) do
    Repo.insert!(%Finding{
      machine_id: m.id,
      kind: kind,
      key: key,
      origin: origin,
      why: "why " <> key,
      detail: Map.merge(%{"label" => key, "saw" => "Running"}, extra)
    })
  end

  defp changed(view) do
    send(view.pid, :issues_changed)
    send(view.pid, {:settled, :page})
    :sys.get_state(view.pid)
    render(view)
  end

  defp seed do
    big = machine("big-box")
    small = machine("small-box", "windows")
    empty = machine("quiet-box")
    hushed = machine("hushed-box")

    for n <- 1..3, do: finding(big, "service", "mine-#{n}", "yours")
    finding(big, "service", "pkg-1", "software")
    for n <- 1..2, do: finding(big, "service", "os-#{n}", "system")
    finding(small, "port", "5432", "yours", %{"label" => "Port 5432", "saw" => "postgres.exe"})
    for n <- 1..3, do: finding(hushed, "service", "sys-#{n}", "system")
    %{big: big, small: small, empty: empty, hushed: hushed}
  end

  test "the machine with the most visible findings is chosen when none is asked for", %{
    conn: conn
  } do
    seed()
    {:ok, view, html} = live(conn, "/found")
    assert has_element?(view, "#machine-list a[aria-current=true]", "big-box")
    assert html =~ "mine-1"
    refute html =~ "os-1"
    assert html =~ "2 system hidden"
  end

  test "the list is the hook that keeps the chosen machine in view", %{conn: conn} do
    seed()
    {:ok, view, _} = live(conn, "/found?machine=small-box")
    assert has_element?(view, "#machine-list[phx-hook=MachineKeys]")
    assert has_element?(view, "#machine-list a[aria-current=true][tabindex='0']", "small-box")
  end

  test "a machine is chosen by the link and the choice survives a reload", %{conn: conn} do
    seed()
    {:ok, view, _} = live(conn, "/found?machine=small-box")
    assert has_element?(view, "#machine-list a[aria-current=true]", "small-box")
    assert render(view) =~ "Port 5432"
    refute render(view) =~ "mine-1"

    view |> element("#machine-list a", "big-box") |> render_click()
    assert_patch(view, "/found?machine=big-box")
    assert render(view) =~ "mine-1"
    {:ok, _, html} = live(conn, "/found?machine=big-box")
    assert html =~ "mine-1"
  end

  test "hidden counts are given in total and for each machine, and the toggle shows them", %{
    conn: conn
  } do
    seed()
    {:ok, view, html} = live(conn, "/found")
    assert html =~ "5 system hidden"
    assert has_element?(view, "#machine-list a", "hushed-box")
    assert has_element?(view, "#machine-list a", "3 system hidden")
    assert has_element?(view, "#machine-list a", "2 system hidden")

    view |> form("#system-form", %{"system" => "true"}) |> render_change()
    assert_patch(view, "/found?system=true")
    html = render(view)
    assert html =~ "System shown"
    refute html =~ "system hidden"
    assert html =~ "os-1"

    view |> element("#machine-list a", "quiet-box") |> render_click()
    assert_patch(view, "/found?machine=quiet-box&system=true")
  end

  test "a machine whose findings are all system says so and offers to show them", %{conn: conn} do
    seed()
    {:ok, view, _} = live(conn, "/found?machine=hushed-box")
    assert has_element?(view, "#panel-empty", "3 findings here are system ones, hidden.")
    view |> element("#panel-empty button", "Show system services") |> render_click()
    assert_patch(view, "/found?machine=hushed-box&system=true")
    assert render(view) =~ "sys-1"
  end

  test "a machine with nothing found has its own empty state", %{conn: conn} do
    seed()
    {:ok, view, _} = live(conn, "/found?machine=quiet-box")
    assert has_element?(view, "#panel-empty", "No scan has reported from quiet-box yet")
  end

  test "no machine at all has its own empty state", %{conn: conn} do
    {:ok, view, _} = live(conn, "/found")
    assert has_element?(view, "#no-machines", "No machine has joined yet.")
  end

  test "a section's Watch all acts only on what is shown", %{conn: conn} do
    %{big: big, small: small} = seed()
    {:ok, view, _} = live(conn, "/found?machine=big-box")
    assert has_element?(view, "button", "Watch all 4")
    view |> element("button", "Watch all 4") |> render_click()

    assert [%{machine_id: id}] = Dokkit.Found.list()
    assert id == small.id

    assert [%{origin: "system"}, %{origin: "system"}] =
             Enum.filter(Dokkit.Found.list(system: true), &(&1.machine_id == big.id))

    assert Repo.get_by(Dokkit.Service, machine_id: big.id, slug: "mine-1")
    refute Repo.get_by(Dokkit.Service, machine_id: big.id, slug: "os-1")
  end

  test "a selection acts on its rows, and survives an update that leaves them", %{conn: conn} do
    %{big: big} = seed()
    {:ok, view, _} = live(conn, "/found?machine=big-box")
    assert render(view) =~ "None selected"

    [a, b | _] = Dokkit.Found.list() |> Enum.filter(&(&1.machine_id == big.id))
    view |> element("#f-#{a.id} input[type=checkbox]") |> render_click()
    view |> element("#f-#{b.id} input[type=checkbox]") |> render_click()
    assert render(view) =~ "2 selected"

    finding(big, "service", "late-1", "yours")
    html = changed(view)
    assert html =~ "late-1"
    assert html =~ "2 selected"

    Dokkit.Found.dismiss([a.id])
    assert changed(view) =~ "1 selected"

    view |> element("button", "Watch selected") |> render_click()
    assert Repo.get_by(Dokkit.Service, machine_id: big.id, slug: Dokkit.Found.slug(b.key))
    assert render(view) =~ "None selected"
  end

  test "a row is watched or dismissed on its own", %{conn: conn} do
    %{small: small} = seed()
    {:ok, view, _} = live(conn, "/found?machine=small-box")
    [f] = Dokkit.Found.list() |> Enum.filter(&(&1.machine_id == small.id))
    view |> element("#f-#{f.id} button[aria-label='Dismiss Port 5432']") |> render_click()
    assert Dokkit.Found.list() |> Enum.filter(&(&1.machine_id == small.id)) == []
  end

  test "a found job opens to say how its runs are reported", %{conn: conn} do
    m = machine("job-box")
    job = finding(m, "job", "nightly", "yours", %{"record" => "wrapper", "command" => "/bin/x"})
    {:ok, view, html} = live(conn, "/found?machine=job-box")
    refute html =~ "Needs the wrapper."
    view |> element("#f-#{job.id} button[aria-label='Details of nightly']") |> render_click()
    assert render(view) =~ "Needs the wrapper."
    assert render(view) =~ "dokkit run --job nightly -- /bin/x"
  end
end
