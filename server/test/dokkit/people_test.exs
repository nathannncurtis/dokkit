defmodule Dokkit.PeopleTest do
  use Dokkit.DataCase, async: false
  alias Dokkit.{Accounts, Alert, Alerts, Digest, Intake, Keys, Machine, People, Repo, Service}

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
      send(test, {:sent, conn.host, body})
      Plug.Conn.send_resp(conn, 202, "{}")
    end)

    {:ok, ada} = Accounts.add("ada", "member", "a long enough password")
    {:ok, ben} = Accounts.add("ben", "member", "a long enough password")
    People.update(ada.id, %{"pagerduty_key" => "ADA-KEY", "email" => "ada@example.test"})
    People.update(ben.id, %{"pagerduty_key" => "BEN-KEY", "email" => "ben@example.test"})
    Alerts.save(%{"pagerduty_key" => "TEAM-KEY"})
    %{key: key, service: service, ada: ada, ben: ben}
  end

  defp keys do
    receive do
      {:sent, "events.pagerduty.com", body} ->
        e = Jason.decode!(body)
        [{e["routing_key"], e["event_action"], e["dedup_key"]} | keys()]
    after
      0 -> []
    end
  end

  test "with nobody named the server-wide key is paged, as before", %{key: key} do
    Intake.ping(key, "backup", "fail", nil, "")
    assert Alerts.deliver_pending() == 1
    assert [{"TEAM-KEY", "trigger", "dokkit-" <> id}] = keys()
    refute id =~ "-" <> "ADA"
  end

  test "a service names a person: their key is paged and resolved, the team's is not", %{
    key: key,
    service: service,
    ada: ada
  } do
    assert {:ok, _} = People.set_who("service", service.id, [ada.id])
    Intake.ping(key, "backup", "fail", nil, "")
    Alerts.deliver_pending()
    assert [{"ADA-KEY", "trigger", dedup}] = keys()
    assert dedup =~ ada.id

    Intake.ping(key, "backup", "ok", nil, "")
    Alerts.deliver_pending()
    assert [{"ADA-KEY", "resolve", ^dedup}] = keys()
  end

  test "the check beats the service, the service the rule, the rule the default", %{
    service: service,
    ada: ada,
    ben: ben
  } do
    check = Repo.insert!(%Dokkit.Check{service_id: service.id, name: "c", type: :job})
    assert People.audience(check: check.id, service: service.id, rule: "r") == :everyone
    People.set_who("default", "", [ben.id])
    assert People.audience(check: check.id, service: service.id, rule: "r") == [ben.id]
    Repo.insert!(%Dokkit.Setting{key: "rules", value: %{"list" => [%{"id" => "r"}]}})
    People.set_who("rule", "r", [ada.id, ben.id])

    assert Enum.sort(People.audience(check: check.id, service: service.id, rule: "r")) ==
             Enum.sort([ada.id, ben.id])

    People.set_who("service", service.id, [ada.id])
    assert People.audience(check: check.id, service: service.id, rule: "r") == [ada.id]
    People.set_who("check", check.id, ["everyone"])
    assert People.audience(check: check.id, service: service.id, rule: "r") == :everyone
    assert {:error, _} = People.set_who("check", check.id, ["everyone", ada.id])
    assert {:error, _} = People.set_who("service", service.id, ["nobody"])
  end

  test "one failing person is retried alone and the others are not told twice", %{
    key: key,
    service: service,
    ada: ada,
    ben: ben
  } do
    People.update(ben.id, %{"pagerduty_key" => ""})
    People.set_who("service", service.id, [ada.id, ben.id])
    Intake.ping(key, "backup", "fail", nil, "")
    Alerts.deliver_pending()
    assert [{"ADA-KEY", "trigger", _}] = keys()

    assert %Alert{status: :failed, error: "ben: PagerDuty has no routing key yet."} =
             Repo.one(Alert)

    Repo.update_all(Alert, set: [updated_at: DateTime.add(DateTime.utc_now(), -120)])
    People.update(ben.id, %{"pagerduty_key" => "BEN-KEY"})
    Alerts.deliver_pending()
    assert [{"BEN-KEY", "trigger", _}] = keys()
  end

  test "a test goes to the person's own destination" do
    ada = Enum.find(People.list(), &(&1.name == "ada"))
    assert Alerts.test("page", ada) == :ok
    assert [{"ADA-KEY", "trigger", _}, {"ADA-KEY", "resolve", _}] = keys()
  end

  test "the digest goes to each person with what was theirs", %{service: service, ada: ada} do
    People.set_who("service", service.id, [ada.id])
    machine = Repo.insert!(%Machine{name: "digest-box"})

    mine =
      Repo.insert!(%Dokkit.Issue{
        machine_id: machine.id,
        service_id: service.id,
        kind: "check",
        state: :degraded,
        title: "ada only",
        since: DateTime.utc_now()
      })

    other =
      Repo.insert!(%Dokkit.Issue{
        machine_id: machine.id,
        kind: "machine",
        state: :degraded,
        title: "for all",
        since: DateTime.utc_now()
      })

    for i <- [mine, other],
        do: Repo.insert!(%Alert{issue_id: i.id, channel: "push", status: :sent})

    People.target(Repo.get_by!(Alert, issue_id: mine.id).id, [ada.id])
    since = DateTime.add(DateTime.utc_now(), -3600)

    assert Digest.lines(since) |> Enum.join("\n") =~ "for all"
    refute Digest.lines(since) |> Enum.join("\n") =~ "ada only"
    assert Digest.lines(since, [], ada.id) |> Enum.join("\n") =~ "ada only"
    refute Digest.lines(since, [], ada.id) |> Enum.join("\n") =~ "for all"
  end

  test "Dokkit's own row pages for the highest channel set up, and pushes lesser trouble" do
    assert Alerts.self_routes(%{"pagerduty_key" => "K"}) == {"page", "push"}
    assert Alerts.self_routes(%{"email_to" => "a@example.test"}) == {"email", "push"}

    assert Alerts.self_routes(%{"self_down" => "sms", "self_degraded" => "email"}) ==
             {"sms", "email"}

    Alerts.save(%{"pagerduty_key" => "K"})
    Dokkit.Self.tick(DateTime.utc_now(), Alerts.config())
    assert %{route_down: "page", route_degraded: "push"} = Repo.get_by!(Service, slug: "dokkit")
  end

  test "iMessage says what is missing until the Mac answers a test" do
    assert {:missing, "No Mac is chosen yet."} = Alerts.imessage_status(%{})
    mac = Repo.insert!(%Machine{name: "mac-mini", kind: :enrolled, os: "darwin"})
    config = %{"imessage_machine" => mac.id, "imessage_to" => ""}
    assert {:missing, "No address is set to send to."} = Alerts.imessage_status(config)
    config = %{config | "imessage_to" => "+15555550100"}
    assert {:missing, "mac-mini is chosen. Send a test" <> _} = Alerts.imessage_status(config)
    Application.put_env(:dokkit, :imessage_test_wait, 0)
    on_exit(fn -> Application.delete_env(:dokkit, :imessage_test_wait) end)
    Alerts.save(%{"imessage_machine" => mac.id, "imessage_to" => "+15555550100"})
    assert {:error, _} = Alerts.test("imessage")

    assert {:missing, "mac-mini is chosen but its program has not picked up" <> _} =
             Alerts.imessage_status(config)
  end

  test "an issue that opens again inside 30 minutes is told to whoever is named now", %{
    key: key,
    service: service,
    ada: ada,
    ben: ben
  } do
    People.set_who("service", service.id, [ada.id])
    Intake.ping(key, "backup", "fail", nil, "")
    Alerts.deliver_pending()
    Intake.ping(key, "backup", "ok", nil, "")
    Alerts.deliver_pending()
    keys()

    People.set_who("service", service.id, [ben.id])
    Intake.ping(key, "backup", "fail", nil, "")
    Alerts.deliver_pending()
    assert [{"BEN-KEY", "trigger", _}] = keys()
  end

  test "an email goes to the person named, not the server-wide address", %{
    key: key,
    service: service,
    ada: ada
  } do
    Alerts.save(%{"email_to" => "team@example.test"})
    Dokkit.Estate.set_routing(Repo.get!(Service, service.id), %{"down" => "email"})
    People.set_who("service", service.id, [ada.id])
    Intake.ping(key, "backup", "fail", nil, "")
    Alerts.deliver_pending()
    assert_received {:mail, "ada@example.test", _, _}
    refute_received {:mail, "team@example.test", _, _}
  end
end
