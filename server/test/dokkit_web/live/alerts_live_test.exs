defmodule DokkitWeb.AlertsLiveTest do
  use DokkitWeb.ConnCase, async: false
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
        alerts: %{down: ["push"], pagerduty_key: "S3CRET", ntfy_url: "https://ntfy.example/t"}
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

  test "an address that is not https is refused and not saved", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn), "/alerts")

    html =
      view
      |> form("#alerts-form", alerts: %{webhook_url: "http://hook-refused.example/x"})
      |> render_submit()

    assert html =~ "webhook: The address must start with https://."
    refute html =~ "Saved."
  end

  test "someone who is not the owner is not shown the addresses and user", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn), "/alerts")

    view
    |> form("#alerts-form",
      alerts: %{
        ntfy_url: "https://ntfy-seen.example/t",
        webhook_url: "https://hook-seen.example/x",
        heartbeat_url: "https://beat-seen.example/y",
        smtp_user: "smtp-seen-user"
      }
    )
    |> render_submit()

    viewer = Repo.insert!(%User{name: "vic-sees", password_hash: "-", role: :viewer})

    {:ok, _, html} =
      live(
        Plug.Test.init_test_session(conn, %{
          "user_id" => viewer.id,
          "signed_at" => Dokkit.Accounts.stamp()
        }),
        "/alerts"
      )

    for v <- ~w(ntfy-seen hook-seen beat-seen smtp-seen-user), do: refute(html =~ v)
  end

  test "someone who is not the owner cannot change them", %{conn: conn} do
    viewer = Repo.insert!(%User{name: "vic", password_hash: "-", role: :viewer})

    {:ok, view, html} =
      live(
        Plug.Test.init_test_session(conn, %{
          "user_id" => viewer.id,
          "signed_at" => Dokkit.Accounts.stamp()
        }),
        "/alerts"
      )

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
      |> form("#rule-form",
        rule: %{kind: "job", state: "down", machine: "nas", channel: ["email"]}
      )
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

  test "a refused save keeps what was typed in the other fields", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn), "/alerts")

    view |> form("#alerts-form", alerts: %{email_to: "keep@example.com"}) |> render_change()

    html =
      view
      |> form("#alerts-form", alerts: %{night_from: "25"})
      |> render_submit()

    assert html =~ ~s(value="keep@example.com")
    assert html =~ ~s(value="25")
  end

  test "Send a test uses the Mac and address chosen in the form, without a change event first",
       %{conn: conn} do
    mac = Repo.insert!(%Dokkit.Machine{name: "mac-mini", kind: :enrolled, os: "darwin"})
    {:ok, view, _} = live(signed_in(conn), "/alerts")

    html =
      view
      |> form("#alerts-form", alerts: %{imessage_machine: mac.id, imessage_to: "+15555550100"})
      |> render_submit(%{"test" => "imessage"})

    assert html =~ "Waiting for the Mac to answer."
    assert %{"imessage_machine" => id, "imessage_to" => "+15555550100"} = Alerts.config()
    assert id == mac.id
  end

  test "Save and look up lists the PagerDuty schedules and who is on call", %{conn: conn} do
    Req.Test.stub(Alerts, fn conn ->
      body =
        if conn.request_path == "/schedules",
          do: %{"schedules" => [%{"id" => "PSCHED9", "name" => "Weekend"}]},
          else: %{"users" => [%{"name" => "Una", "email" => "una@example.test"}]}

      Req.Test.json(conn, body)
    end)

    {:ok, view, _} = live(signed_in(conn), "/alerts")

    html =
      view
      |> form("#alerts-form",
        alerts: %{pagerduty_api_key: "REST-LIVE-#{System.unique_integer([:positive])}"}
      )
      |> render_submit(%{
        "oncall" => "pagerduty",
        "alerts" => %{"pagerduty_schedule" => "PSCHED9"}
      })

    assert html =~ "Weekend"
    assert html =~ "On call now: Una (una@example.test)"
    assert html =~ "nobody on this server"
    assert Alerts.config()["pagerduty_schedule"] == "PSCHED9"
  end
end
