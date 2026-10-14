defmodule DokkitWeb.UpdateScreenTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias Dokkit.{Machine, Repo}

  setup %{conn: conn} do
    m =
      Repo.insert!(%Machine{
        name: "vault",
        kind: :enrolled,
        has_updater: true,
        program_version: "v1.0.0"
      })

    %{conn: signed_in(conn), m: m}
  end

  defp change(m, set), do: Repo.update_all(from(x in Machine, where: x.id == ^m.id), set: set)

  defp flush(view) do
    send(view.pid, {:settled, :shell})
    send(view.pid, {:settled, :page})
    render(view)
  end

  test "the screen replaces a page while an update runs and goes when it is done", %{
    conn: conn,
    m: m
  } do
    {:ok, view, html} = live(conn, "/all")
    refute html =~ "Updating to"
    assert has_element?(view, "h1", "Everything")

    change(m, wanted_version: "v1.1.0", update_started_at: DateTime.utc_now())
    Dokkit.Issues.changed(false)
    flush(view)

    assert has_element?(view, "#updating h1", "Updating to v1.1.0")

    assert has_element?(
             view,
             ~s|#updating [role=progressbar][aria-valuenow="0"][aria-valuemax="1"]|
           )

    assert has_element?(view, "#updating-#{m.id}", "Waiting")
    refute has_element?(view, "h1", "Everything")
    refute has_element?(view, "nav")
    refute has_element?(view, "a")

    change(m, wanted_version: nil, update_ok: true, update_version: "v1.1.0")
    Dokkit.Issues.changed(false)
    flush(view)

    refute has_element?(view, "#updating")
    assert has_element?(view, "h1", "Everything")
  end

  test "every live page shows it", %{conn: conn, m: m} do
    change(m,
      wanted_version: "v1.1.0",
      update_started_at: DateTime.utc_now(),
      update_asked_at: DateTime.utc_now()
    )

    for path <- ["/", "/jobs", "/apps", "/machines/#{m.id}", "/settings"] do
      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "#updating-#{m.id}", "Installing"), path
    end
  end

  test "a failed machine leaves a notice on Everything until dismissed", %{conn: conn, m: m} do
    change(m,
      wanted_version: "v1.1.0",
      update_ok: false,
      update_version: "v1.1.0",
      update_note: "file in use",
      update_started_at: DateTime.utc_now()
    )

    {:ok, view, _} = live(conn, "/all")
    refute has_element?(view, "#updating")
    assert has_element?(view, "#update-failed", "vault")
    assert has_element?(view, "#update-failed", "file in use")

    view |> element("#update-failed button", "Dismiss") |> render_click()
    flush(view)
    refute has_element?(view, "#update-failed")
  end

  test "a machine that never answers is shown as failed after 20 minutes", %{conn: conn, m: m} do
    change(m,
      wanted_version: "v1.1.0",
      update_started_at: DateTime.add(DateTime.utc_now(), -1300)
    )

    {:ok, view, _} = live(conn, "/all")
    refute has_element?(view, "#updating")
    assert has_element?(view, "#update-failed", "did not report back within 20 minutes")
  end
end
