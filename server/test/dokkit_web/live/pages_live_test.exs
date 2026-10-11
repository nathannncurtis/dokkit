defmodule DokkitWeb.PagesLiveTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Dokkit.{Estate, Keys, Repo}

  setup %{conn: conn}, do: %{conn: signed_in(conn)}

  test "a job is added in the interface, pinged, and shows on every page", %{conn: conn} do
    {:ok, view, html} = live(conn, "/jobs/new")
    assert html =~ "What to watch"

    bad =
      view
      |> form("#job-form",
        job: %{name: "Nightly backup", machine: "nas", schedule: "every night"}
      )
      |> render_submit()

    assert bad =~ "not a cron line"

    html =
      view
      |> form("#job-form",
        job: %{name: "Nightly backup", machine: "nas", schedule: "0 1 * * *", grace: "30m"}
      )
      |> render_submit()

    assert html =~ "Nightly backup is being watched"
    [_, key] = Regex.run(~r{/api/v1/in/(dka_\w+)/job/nightly-backup/fail}, html)
    assert {:ok, _} = Keys.verify(key, :app)

    again = view |> element("a", "Open Nightly backup") |> render() =~ "/s/"
    assert again

    post(
      build_conn() |> put_req_header("content-type", "text/plain"),
      "/api/v1/in/#{key}/job/nightly-backup/fail",
      "rsync: no route to host"
    )

    {:ok, _, html} = live(conn, "/jobs")
    assert html =~ "Nightly backup"
    assert html =~ "Failed"
    assert html =~ "0 1 * * *"

    {:ok, _, html} = live(conn, "/all")
    assert html =~ "1 needs a look"
    assert html =~ "rsync: no route to host"

    {:ok, view, _} = live(conn, "/all")

    assert has_element?(view, ~s|[role=group][aria-labelledby^=mh-] > .grp + .foot ~ .kid|) or
             has_element?(view, ~s|[role=group][aria-labelledby^=mh-] > .grp ~ a.kid|)

    [%{services: [service]}] = Estate.machines()
    {:ok, view, html} = live(conn, "/s/#{service.id}")
    assert html =~ "Nightly backup failed"
    assert html =~ "rsync: no route to host"
    assert html =~ "Next expected"
    assert html =~ "As set on Alerts (Page)"

    view |> form("#route-form", route: %{down: "push"}) |> render_change()
    assert Repo.reload!(service).route_down == "push"
    view |> form("#route-form", route: %{down: ""}) |> render_change()
    assert Repo.reload!(service).route_down == nil

    {:ok, _, html} = live(conn, "/")
    assert html =~ ~s(href="/s/#{service.id}")
  end

  test "the same name twice on one machine is refused", %{conn: conn} do
    {:ok, _} = Estate.add_job(%{"name" => "Purge", "machine" => "nas"})

    assert {:error, "nas already has something called purge."} =
             Estate.add_job(%{"name" => "purge", "machine" => "nas"})

    assert {:error, _} =
             Estate.add_job(%{"name" => "Purge", "machine" => "nas2", "grace" => "soon"})

    {:ok, _, html} = live(conn, "/jobs")
    assert html =~ "No run seen yet"
  end

  test "an unknown service goes back to Everything", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/all"}}} = live(conn, "/s/nope")
  end
end
