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

  test "a rule sends one kind of issue somewhere else", %{conn: conn} do
    {:ok, view, html} = live(signed_in(conn), "/alerts")
    assert html =~ "No rules."

    html =
      view
      |> form("#rule-form", rule: %{kind: "job", state: "down", machine: "nas", channel: "email"})
      |> render_submit()

    assert html =~ "When a job stops on nas: Email"
    [rule] = Dokkit.Alerts.rules()

    Dokkit.Alerts.save(%{"email_to" => "me@example.com"})
    {:ok, job} = Dokkit.Estate.add_job(%{"name" => "Nightly backup", "machine" => "nas"})
    post(build_conn(), "/api/v1/in/#{job.key}/job/nightly-backup/fail")
    assert [%{channel: "email"}] = Dokkit.Repo.all(Dokkit.Alert)

    render_click(view, "rule", %{"toggle" => rule["id"]})
    assert [%{"on" => false}] = Dokkit.Alerts.rules()
    render_click(view, "rule", %{"remove" => rule["id"]})
    assert Dokkit.Alerts.rules() == []
  end

  test "an issue snoozed over and over is offered the digest, and a person decides", %{conn: conn} do
    {:ok, a} = Dokkit.Estate.add_job(%{"name" => "Flaky sync", "machine" => "attic"})
    {:ok, b} = Dokkit.Estate.add_job(%{"name" => "Noisy probe", "machine" => "attic"})

    # Each recovery and relapse reopens the same issue and counts once more.
    for job <- [a, b], round <- 1..6 do
      if round > 1, do: post(build_conn(), "/api/v1/in/#{job.key}/job/#{job.service.slug}/ok")
      post(build_conn(), "/api/v1/in/#{job.key}/job/#{job.service.slug}/fail")
    end

    mine = [a.service.id, b.service.id]
    ids = for i <- Dokkit.Issues.open_list(), i.service_id in mine, do: i.id
    Dokkit.Issues.snooze(ids, 3600)

    {:ok, view, html} = live(signed_in(conn), "/alerts")
    assert html =~ "Flaky sync has needed a look 6 times"
    [one, two] = Dokkit.Alerts.suggestions()

    render_click(view, "suggestion", %{"accept" => one.id})
    assert Dokkit.Repo.get!(Dokkit.Service, one.service_id).route_down == "digest"
    html = render_click(view, "suggestion", %{"dismiss" => two.id})
    refute html =~ "Suggestions"
    assert Dokkit.Repo.get!(Dokkit.Service, two.service_id).route_down == nil
    assert Dokkit.Alerts.suggestions() == []
  end
end
