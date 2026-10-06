defmodule Dokkit.AlertsTest do
  use Dokkit.DataCase, async: true
  alias Dokkit.{Alert, Alerts, Intake, Issues, Keys, Machine, Repo, Service}

  setup do
    machine = Repo.insert!(%Machine{name: "vault"})

    service =
      Repo.insert!(%Service{
        machine_id: machine.id,
        slug: "backup",
        name: "Nightly backup",
        kind: :job
      })

    {_, key} = Keys.mint(:app, %{service_id: service.id})
    test = self()

    Req.Test.stub(Alerts, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:sent, conn.host, body, conn.req_headers})
      Plug.Conn.send_resp(conn, 202, "{}")
    end)

    %{key: key, service: service}
  end

  test "a failed job pages once and the page is resolved when it recovers", %{key: key} do
    Alerts.save(%{"pagerduty_key" => "R0UTE"})

    Intake.ping(key, "backup", "fail", nil, "disk full")
    assert Alerts.deliver_pending() == 1
    assert_received {:sent, "events.pagerduty.com", body, _}

    assert %{"event_action" => "trigger", "routing_key" => "R0UTE", "dedup_key" => "dokkit-" <> _} =
             event = Jason.decode!(body)

    assert event["payload"]["severity"] == "critical"
    assert event["payload"]["summary"] =~ "Nightly backup failed (vault, DOK-"
    assert [%{alert: %Alert{status: :sent}}] = Issues.open_list()

    Intake.ping(key, "backup", "fail", nil, "")
    assert Alerts.deliver_pending() == 0

    Intake.ping(key, "backup", "ok", nil, "")
    assert Alerts.deliver_pending() == 1
    assert_received {:sent, "events.pagerduty.com", body, _}
    assert %{"event_action" => "resolve"} = Jason.decode!(body)

    Intake.ping(key, "backup", "fail", nil, "")
    assert Alerts.deliver_pending() == 0
    refute_received {:sent, _, _, _}
  end

  test "a channel that is not set up is reported, and sent once it is", %{key: key} do
    Intake.ping(key, "backup", "fail", nil, "")
    Alerts.deliver_pending()

    assert [%{alert: %Alert{status: :failed, error: "PagerDuty has no routing key yet."}}] =
             Issues.open_list()

    Alerts.save(%{"down" => "push", "pagerduty_key" => "R0UTE"})
    assert Alerts.config()["down"] == "push"
    Alerts.save(%{"pagerduty_key" => ""})
    assert Alerts.config()["pagerduty_key"] == "R0UTE"

    Alerts.deliver_pending()
    assert_received {:sent, "events.pagerduty.com", _, _}
    assert [%{alert: %Alert{status: :sent}}] = Issues.open_list()
  end

  test "push goes to ntfy, quietly; other environments stay silent", %{key: key, service: service} do
    Alerts.save(%{
      "down" => "push",
      "ntfy_url" => "https://ntfy.example/ops",
      "ntfy_token" => "tk"
    })

    Intake.ping(key, "backup", "fail", nil, "disk full")
    Alerts.deliver_pending()
    assert_received {:sent, "ntfy.example", "disk full", headers}
    assert {"priority", "low"} in headers
    assert {"authorization", "Bearer tk"} in headers

    Intake.ping(key, "backup", "ok", nil, "")
    Repo.update!(Ecto.Changeset.change(service, environment: "dev"))
    Repo.delete_all(Dokkit.Issue)
    Intake.ping(key, "backup", "fail", nil, "")
    assert Alerts.deliver_pending() == 0
  end

  test "a test message says what is missing" do
    assert Alerts.test("webhook") == {:error, "The webhook has no address yet."}
    Alerts.save(%{"webhook_url" => "https://hooks.example/x"})
    assert Alerts.test("webhook") == :ok
    assert_received {:sent, "hooks.example", body, _}
    assert %{"event" => "opened", "issue" => %{"id" => "DOK-0"}} = Jason.decode!(body)
  end

  test "email and text go through the mail server, and the digest is one mail a day" do
    Alerts.save(%{"down" => "email", "degraded" => "digest", "email_to" => "me@example.com"})
    machine = Repo.insert!(%Machine{name: "press"})
    Repo.insert!(%Service{machine_id: machine.id, slug: "spool", name: "Spooler"})
    {_, key} = Keys.mint(:machine, %{machine_id: machine.id})

    line = fn state ->
      ~s({"type":"state","service":"spool","check":"http","state":"#{state}"})
    end

    Intake.report(key, nil, Enum.join([line.("down"), line.("down"), line.("down")], "\n"))

    assert Alerts.deliver_pending() == 1
    assert_received {:mail, "me@example.com", "Spooler: http is down" <> _, body}
    assert body =~ "On press."

    Intake.report(key, nil, Enum.join([line.("ok"), line.("ok"), line.("ok")], "\n"))
    Repo.insert!(%Service{machine_id: machine.id, slug: "queue", name: "Queue"})
    slow = ~s({"type":"state","service":"queue","check":"depth","state":"degraded"})
    Intake.report(key, nil, Enum.join([slow, slow, slow], "\n"))
    Alerts.deliver_pending()
    refute_received {:mail, _, "Queue" <> _, _}

    config = Alerts.config()
    now = DateTime.utc_now()
    early = %{now | hour: 6, minute: 0}
    late = %{now | hour: 7, minute: 30}
    assert Dokkit.Digest.tick(early, config) == :not_yet
    assert Dokkit.Digest.tick(late, config) == :sent
    assert_received {:mail, "me@example.com", "Dokkit: yesterday", body}

    assert :ok =
             Dokkit.Mail.send("a@example.com; b@example.com,c@example.com", "Hello", ["x"], %{})

    assert_received {:mail, "a@example.com, b@example.com, c@example.com", "Hello", "x"}
    assert body =~ "Opened without paging:"
    assert body =~ "Queue"
    assert Dokkit.Digest.tick(late, config) == :not_yet
  end

  test "Dokkit calls the outside address and keeps a row for itself" do
    assert_receive_nothing = fn -> refute_received {:sent, _, _, _} end
    assert_receive_nothing.()
    Dokkit.Self.tick(DateTime.utc_now(), %{"heartbeat_url" => "https://beat.example/abc"})
    assert_received {:sent, "beat.example", _, _}
    assert %{state: :ok, version: version} = Repo.get_by!(Service, slug: "dokkit")
    assert version =~ "."
    assert [%{name: "database.size_mb"}] = Repo.all(Dokkit.Metric)

    # Every enrolled machine quiet at once is Dokkit's own news.
    now = DateTime.utc_now()

    Repo.insert!(%Dokkit.Machine{
      name: "loft",
      kind: :enrolled,
      last_seen_at: DateTime.add(now, -1200)
    })

    Dokkit.Self.tick(now, %{})

    assert %{state: :degraded, note: "No machine has reported for 20 minutes."} =
             Repo.get_by!(Service, slug: "dokkit")

    # A server that has just started has not heard from anyone yet.
    Dokkit.Self.tick(now, %{}, now)
    assert %{state: :ok} = Repo.get_by!(Service, slug: "dokkit")

    Dokkit.Self.tick(now, %{})
    assert %{state: :degraded} = Repo.get_by!(Service, slug: "dokkit")
    Repo.update_all(Dokkit.Machine, set: [last_seen_at: now])
    Dokkit.Self.tick(now, %{})
    assert %{state: :ok} = Repo.get_by!(Service, slug: "dokkit")
  end
end
