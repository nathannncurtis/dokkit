defmodule DokkitWeb.AlertsLiveTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Dokkit.{Alerts, Repo, User}

  test "the owner sets channels, secrets are never sent back, and a test reports what is missing",
       %{conn: conn} do
    {:ok, view, html} = live(signed_in(conn), "/alerts")
    assert html =~ "Who is told"

    assert render_click(view, "test", %{"channel" => "page"}) =~
             "PagerDuty has no routing key yet."

    html =
      view
      |> form("#alerts-form",
        alerts: %{down: "push", pagerduty_key: "S3CRET", ntfy_url: "https://ntfy.example/t"}
      )
      |> render_submit()

    assert html =~ "Saved."
    refute html =~ "S3CRET"
    assert html =~ "kept, type to replace"

    assert %{
             "down" => "push",
             "pagerduty_key" => "S3CRET",
             "ntfy_url" => "https://ntfy.example/t"
           } = Alerts.config()
  end

  test "someone who is not the owner cannot change them", %{conn: conn} do
    viewer = Repo.insert!(%User{name: "vic", password_hash: "-", role: :viewer})

    {:ok, view, html} =
      live(Plug.Test.init_test_session(conn, %{"user_id" => viewer.id}), "/alerts")

    assert html =~ "Only the owner can change these."
    render_submit(view, "save", %{"alerts" => %{"down" => "none"}})
    render_click(view, "test", %{"channel" => "page"})
    assert Alerts.config()["down"] == "page"
  end
end
