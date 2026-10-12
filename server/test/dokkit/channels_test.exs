defmodule Dokkit.ChannelsTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias Dokkit.{Alert, Alerts, Check, Digest, Estate, Issues, Machine, Repo, Service}

  setup do
    Alerts.save(%{
      "pagerduty_key" => "K",
      "email_to" => "me@example.test",
      "night_from" => "22",
      "night_to" => "7"
    })

    test = self()

    Req.Test.stub(Alerts, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:sent, conn.host, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 202, "{}")
    end)

    :ok
  end

  defp job(name, route, night \\ true) do
    machine = Repo.insert!(%Machine{name: "m-" <> name})

    service =
      Repo.insert!(%Service{
        machine_id: machine.id,
        slug: name,
        name: name,
        kind: :job,
        night: night,
        route_down: route
      })

    Repo.insert!(%Check{service_id: service.id, name: name, type: :job, fail_after: 1})
  end

  defp fail(check, at \\ ~U[2026-01-10 12:00:00.000000Z]) do
    Issues.record(check, :down, at: at, now: at, title: "#{check.name} failed")
    issue = Repo.get_by!(Dokkit.Issue, check_id: check.id)
    {issue, Repo.all(from(a in Alert, where: a.issue_id == ^issue.id, order_by: a.channel))}
  end

  describe "several channels for one thing" do
    test "a choice is a list, a string or text with commas, and none stands alone" do
      assert Alerts.split("page") == ["page"]
      assert Alerts.split("page,email") == ["page", "email"]
      assert Alerts.split(["page", "", "pigeon", "page"]) == ["page"]
      assert Alerts.choice(["page", "email"]) == "page,email"
      assert Alerts.channel_error(["page", "none"]) =~ "none cannot be combined"
      assert Alerts.channel_error("page, email") == nil
      assert Alerts.channel_error(5)
      assert Alerts.exclusive(["page", "none"], ["page"]) == ["none"]
      assert Alerts.exclusive(["none", "page"], ["none"]) == ["page"]
    end

    test "a service with page and email makes two alerts that each send and resolve" do
      check = job("both", "page,email")
      {issue, alerts} = fail(check)
      assert Enum.map(alerts, & &1.channel) == ["email", "page"]
      assert Alerts.deliver_pending() == 2

      assert_received {:sent, "events.pagerduty.com", %{"event_action" => "trigger"} = trigger}
      assert trigger["payload"]["severity"] == "critical"

      Issues.record(Repo.reload!(check), :ok, at: ~U[2026-01-10 12:05:00.000000Z])
      assert Alerts.deliver_pending() >= 1
      assert_received {:sent, "events.pagerduty.com", %{"event_action" => "resolve"}}

      assert Repo.all(from a in Alert, where: a.issue_id == ^issue.id, select: a.status)
             |> Enum.all?(&(&1 in [:closed, :sent]))
    end

    test "page and push through PagerDuty make one incident, at the higher severity" do
      Alerts.save(%{"push_with" => "pagerduty"})
      {_, alerts} = fail(job("one", "page,push"))
      assert Enum.map(alerts, & &1.channel) == ["page"]
      Alerts.deliver_pending()
      assert_received {:sent, "events.pagerduty.com", %{"payload" => %{"severity" => "critical"}}}
      refute_received {:sent, _, _}
    end

    test "page and push to ntfy stay two alerts" do
      Alerts.save(%{"push_with" => "ntfy"})
      {_, alerts} = fail(job("two", "page,push"))
      assert Enum.map(alerts, & &1.channel) == ["page", "push"]
    end

    test "the defaults and a rule take lists, and a list of one reads as before" do
      assert {:ok, _, _} = Alerts.update(%{"down" => ["page", "email"], "degraded" => "push"})
      assert Alerts.config()["down"] == "page,email"
      assert Alerts.view()["down_channels"] == ["page", "email"]
      assert {:error, _} = Alerts.update(%{"down" => ["none", "email"]})

      [rule] = Alerts.add_rule(%{"kind" => "job", "channels" => ["sms", "email"]})
      assert rule["channel"] == "sms,email"
      assert [%{"channels" => ["sms", "email"]}] = Alerts.rules()
      assert Alerts.rule_error(%{"channel" => ["none", "email"]})
    end

    test "the service routing answers text and a list, and refuses none with others" do
      s = job("api", nil).service_id
      body = DokkitWeb.ApiController.set_routing(%{"id" => s, "down" => ["page", "email"]})
      assert %{down: "page,email", down_channels: ["page", "email"]} = body

      assert %{down: "page", down_channels: ["page"]} =
               DokkitWeb.ApiController.set_routing(%{"id" => s, "down" => "page"})

      assert {:error, "bad_routing", _} =
               DokkitWeb.ApiController.set_routing(%{"id" => s, "down" => "none,page"})
    end
  end

  describe "a machine going silent" do
    defp silent(name, seen) do
      m = Repo.insert!(%Machine{name: name, kind: :enrolled, last_seen_at: seen})
      m
    end

    test "uses its own channels, and the global down choice when it has none" do
      now = ~U[2026-01-10 23:30:00.000000Z]
      quiet = DateTime.add(now, -600)
      a = silent("silent-a", quiet)
      b = silent("silent-b", quiet)
      Estate.set_silent(b, %{"down" => ["none"]})
      Issues.machines_sweep(now)

      ia = Repo.get_by!(Dokkit.Issue, machine_id: a.id, kind: "machine")
      ib = Repo.get_by!(Dokkit.Issue, machine_id: b.id, kind: "machine")

      assert [%{channel: "page", status: :pending}] =
               Repo.all(from x in Alert, where: x.issue_id == ^ia.id)

      assert Repo.all(from x in Alert, where: x.issue_id == ^ib.id) == []
    end

    test "wakes at night unless told not to, and the alert goes out when the night ends" do
      now = ~U[2026-01-10 23:30:00.000000Z]
      m = silent("silent-c", DateTime.add(now, -600))
      Estate.set_silent(m, %{"down" => "page,email", "night" => false})
      Issues.machines_sweep(now)
      issue = Repo.get_by!(Dokkit.Issue, machine_id: m.id, kind: "machine")
      alerts = Repo.all(from x in Alert, where: x.issue_id == ^issue.id)
      assert Enum.sort(Enum.map(alerts, & &1.channel)) == ["email", "page"]
      assert Enum.all?(alerts, &(&1.status == :held))

      Estate.set_silent(m, %{"night" => true})

      assert Enum.all?(
               Repo.all(from x in Alert, where: x.issue_id == ^issue.id),
               &(&1.status == :pending)
             )
    end

    test "the API sets it and the machine shows it" do
      m = silent("silent-d", DateTime.utc_now())

      assert %{down: "email", down_channels: ["email"], night: false} =
               DokkitWeb.ApiController.set_machine_routing(%{
                 "id" => m.id,
                 "down" => "email",
                 "night" => false
               })

      assert %{silent: %{down: "email"}} = Dokkit.Read.machine(m.id)

      assert {:error, "bad_routing", _} =
               DokkitWeb.ApiController.set_machine_routing(%{"id" => m.id, "down" => "none,page"})
    end

    test "the machine's page has the card and saves it", %{conn: conn} do
      m = silent("silent-e", DateTime.utc_now())
      s = Repo.insert!(%Service{machine_id: m.id, slug: "machine", name: "The machine itself"})
      {:ok, view, html} = live(signed_in(conn), "/s/#{s.id}")
      assert html =~ "If this machine stops reporting"

      view
      |> form("#silent-form", silent: %{down: ["sms", "email"], night: "false"})
      |> render_submit()

      assert %Machine{silent_route: "sms,email", silent_wake: false} = Repo.reload!(m)
    end
  end

  describe "the night in a time zone" do
    test "follows daylight saving: 23:00 and 21:00 local either side of the change" do
      config = %{"night_from" => "22", "night_to" => "7", "night_zone" => "America/Los_Angeles"}

      # Pacific time changes on 2026-03-08 (UTC-8 to UTC-7) and on 2026-11-01 (back).
      assert Alerts.night?(~U[2026-03-08 07:00:00Z], config)
      refute Alerts.night?(~U[2026-03-08 05:00:00Z], config)
      assert Alerts.night?(~U[2026-03-09 06:00:00Z], config)
      refute Alerts.night?(~U[2026-03-09 04:00:00Z], config)
      assert Alerts.night?(~U[2026-03-07 07:00:00Z], config)
      refute Alerts.night?(~U[2026-03-07 05:00:00Z], config)

      assert Alerts.night?(~U[2026-10-31 06:00:00Z], config)
      refute Alerts.night?(~U[2026-10-31 04:00:00Z], config)
      assert Alerts.night?(~U[2026-11-02 07:00:00Z], config)
      refute Alerts.night?(~U[2026-11-02 05:00:00Z], config)
    end

    test "a push is held at 23:00 local and not at 21:00" do
      Alerts.save(%{"night_zone" => "America/Los_Angeles"})

      for {at, status} <- [
            {~U[2026-03-09 06:00:00.000000Z], :held},
            {~U[2026-03-09 04:00:00.000000Z], :pending}
          ] do
        {_, [alert]} = fail(job("tz-#{status}", "push", false), at)
        assert alert.status == status
      end
    end

    test "without a zone the old offset still works, and a bad zone is refused" do
      assert Alerts.night?(~U[2026-01-10 23:30:00Z])

      assert Alerts.night?(~U[2026-01-10 12:00:00Z], %{
               "night_offset" => "10",
               "night_from" => "22",
               "night_to" => "7"
             })

      refute Alerts.zone_set?(Alerts.config())
      assert {:error, text} = Alerts.update(%{"night_zone" => "Mars/Olympus"})
      assert text =~ "night_zone"
      assert {:ok, _, _} = Alerts.update(%{"night_zone" => "Europe/Berlin"})
      assert Alerts.zone_set?(Alerts.config())
    end

    test "the digest time is read in the zone" do
      Alerts.save(%{"night_zone" => "America/Los_Angeles", "digest_at" => "07:00"})
      config = Alerts.config()
      assert Digest.tick(~U[2026-03-09 13:59:00Z], config) == :not_yet
    end

    test "the page warns while no zone is set and checks the zone once it is", %{conn: conn} do
      {:ok, _, html} = live(signed_in(conn), "/alerts")
      assert html =~ "No time zone is chosen"

      Alerts.save(%{"night_zone" => "Europe/Berlin"})
      {:ok, _, html} = live(signed_in(conn), "/alerts")
      assert html =~ "It is now"
      assert html =~ "night is 22:00 to 07:00"
      refute html =~ "No time zone is chosen"
    end
  end

  describe "the test button" do
    test "a page test stays open, then the sweep resolves it, even after a restart" do
      assert Alerts.test("page") == :ok
      assert_received {:sent, "events.pagerduty.com", %{"event_action" => "trigger"} = open}
      refute_received {:sent, _, _}

      assert Alerts.resolve_tests(DateTime.add(DateTime.utc_now(), 60)) == 0
      assert Alerts.resolve_tests(DateTime.add(DateTime.utc_now(), 121)) == 1

      assert_received {:sent, "events.pagerduty.com",
                       %{"event_action" => "resolve", "dedup_key" => key}}

      assert key == open["dedup_key"]
      assert Alerts.resolve_tests(DateTime.add(DateTime.utc_now(), 300)) == 0
    end

    test "a test that sends nothing to PagerDuty resolves nothing" do
      Alerts.save(%{"webhook_url" => "https://hook.example/x"})
      assert Alerts.test("webhook") == :ok
      assert Alerts.resolve_tests(DateTime.add(DateTime.utc_now(), 300)) == 0
      refute Alerts.keeps_open?("webhook")
      assert Alerts.keeps_open?("page")
    end

    test "the page says so beside the button", %{conn: conn} do
      {:ok, _, html} = live(signed_in(conn), "/alerts")
      assert html =~ "This test stays open for two minutes, then resolves itself."
    end
  end
end
