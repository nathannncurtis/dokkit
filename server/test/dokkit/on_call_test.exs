defmodule Dokkit.OnCallTest do
  use Dokkit.DataCase, async: false
  import Ecto.Query
  alias Dokkit.{Accounts, Alert, Alerts, Intake, Keys, Machine, OnCall, People, Repo, Service}

  setup do
    :persistent_term.erase(OnCall)
    machine = Repo.insert!(%Machine{name: "vault"})

    service =
      Repo.insert!(%Service{machine_id: machine.id, slug: "backup", name: "Backup", kind: :job})

    {_, key} = Keys.mint(:app, %{service_id: service.id})
    {:ok, ada} = Accounts.add("ada", "member", "a long enough password")
    {:ok, ben} = Accounts.add("ben", "member", "a long enough password")
    {:ok, _} = Accounts.add("cy", "member", "a long enough password")
    People.update(ada.id, %{"pagerduty_key" => "ADA-KEY", "email" => "Ada@Example.test"})
    People.update(ben.id, %{"pagerduty_key" => "BEN-KEY", "email" => "ben@example.test"})

    Alerts.save(%{
      "pagerduty_key" => "TEAM-KEY",
      "pagerduty_api_key" => "REST-#{System.unique_integer([:positive])}",
      "pagerduty_schedule" => "PSCHED1"
    })

    %{key: key, service: service, ada: ada, ben: ben}
  end

  defp user(email), do: %{"name" => "Someone", "email" => email}

  defp pagerduty(users, opts \\ []) do
    test = self()

    Req.Test.stub(Alerts, fn conn ->
      case {conn.host, conn.request_path} do
        {"api.pagerduty.com", "/schedules"} ->
          Req.Test.json(conn, %{"schedules" => [%{"id" => "PSCHED1", "name" => "Primary"}]})

        {"api.pagerduty.com", path} ->
          send(test, {:rest, path, conn.query_string})
          Process.sleep(opts[:delay] || 0)

          if users == :down,
            do: Plug.Conn.send_resp(conn, 500, "{}"),
            else: Req.Test.json(conn, %{"users" => users})

        {"events.pagerduty.com", _} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          e = Jason.decode!(body)
          send(test, {:paged, e["routing_key"], e["event_action"]})
          status = if e["routing_key"] in (opts[:fail] || []), do: 500, else: 202
          Plug.Conn.send_resp(conn, status, "{}")
      end
    end)
  end

  defp paged do
    receive do
      {:paged, key, action} -> [{key, action} | paged()]
    after
      0 -> []
    end
  end

  defp asked do
    receive do
      {:rest, _, _} -> 1 + asked()
    after
      0 -> 0
    end
  end

  defp retry_now do
    past = NaiveDateTime.add(NaiveDateTime.utc_now(), -120) |> NaiveDateTime.truncate(:second)
    Repo.update_all(Alert, set: [updated_at: past])
  end

  test "reads who is on call in the schedule itself, for now", %{ada: ada} do
    pagerduty([user("ada@example.test")])
    assert {:ok, [%{id: "PSCHED1", name: "Primary"}]} = OnCall.schedules()

    view = OnCall.view()
    assert [%{email: "ada@example.test", person: %{id: id}}] = view.oncall
    assert id == ada.id
    assert_received {:rest, "/schedules/PSCHED1/users", query}
    q = URI.decode_query(query)
    {:ok, since, _} = DateTime.from_iso8601(q["since"])
    {:ok, until, _} = DateTime.from_iso8601(q["until"])
    assert DateTime.diff(until, since) == 60
    assert Alerts.view()["pagerduty_api_key"] == "set"
  end

  test "the person on call is paged on their own key, and resolved there", %{
    key: key,
    service: service
  } do
    pagerduty([user("ada@example.test")])
    assert {:ok, _} = People.set_who("service", service.id, ["oncall"])

    Intake.ping(key, "backup", "fail", nil, "")
    Alerts.deliver_pending()
    assert paged() == [{"ADA-KEY", "trigger"}]

    Intake.ping(key, "backup", "ok", nil, "")
    Alerts.deliver_pending()
    assert paged() == [{"ADA-KEY", "resolve"}]
  end

  test "everyone on call who is here is paged once; users without an email are skipped", %{
    key: key
  } do
    pagerduty([
      user("ada@example.test"),
      %{"name" => "No mail"},
      user("ADA@example.test"),
      user("ben@example.test"),
      user("stranger@example.test")
    ])

    People.set_who("default", "", ["oncall"])
    Intake.ping(key, "backup", "fail", nil, "")
    Alerts.deliver_pending()
    assert Enum.sort(paged()) == [{"ADA-KEY", "trigger"}, {"BEN-KEY", "trigger"}]
  end

  test "nobody here with that email: the server-wide key is paged", %{key: key} do
    pagerduty([user("someone@else.test")])
    People.set_who("default", "", ["oncall"])
    Intake.ping(key, "backup", "fail", nil, "")
    Alerts.deliver_pending()
    assert paged() == [{"TEAM-KEY", "trigger"}]
  end

  test "PagerDuty cannot be reached: the server-wide key is paged, and the failure is not kept",
       %{key: key} do
    pagerduty(:down)
    People.set_who("default", "", ["oncall"])
    Intake.ping(key, "backup", "fail", nil, "")
    Alerts.deliver_pending()
    assert paged() == [{"TEAM-KEY", "trigger"}]
    assert asked() == 1

    pagerduty([user("ada@example.test")])
    assert {:ok, [%{email: "ada@example.test"}]} = OnCall.now()
  end

  test "each try asks again, so a change of who is on call is followed", %{key: key} do
    pagerduty([user("ada@example.test")], fail: ["ADA-KEY"])
    People.set_who("default", "", ["oncall"])
    Intake.ping(key, "backup", "fail", nil, "")
    Alerts.deliver_pending()
    assert paged() == [{"ADA-KEY", "trigger"}]

    :persistent_term.erase(OnCall)
    pagerduty([user("ben@example.test")])
    retry_now()
    Alerts.deliver_pending()
    assert paged() == [{"BEN-KEY", "trigger"}]
  end

  test "when the person on call cannot be reached, the last try goes server-wide", %{key: key} do
    pagerduty([user("ada@example.test")], fail: ["ADA-KEY"])
    People.set_who("default", "", ["oncall"])
    Intake.ping(key, "backup", "fail", nil, "")
    Alerts.deliver_pending()
    assert paged() == [{"ADA-KEY", "trigger"}]

    Repo.update_all(Alert, set: [attempts: 4])
    retry_now()
    Alerts.deliver_pending()
    assert paged() == [{"TEAM-KEY", "trigger"}]
  end

  test "a burst of lookups, at once or one after another, asks PagerDuty once" do
    pagerduty([user("ada@example.test")], delay: 200)

    1..5
    |> Enum.map(fn _ -> Task.async(fn -> OnCall.people() end) end)
    |> Enum.each(&assert({:ok, [_]} = Task.await(&1)))

    for _ <- 1..3, do: assert({:ok, [_]} = OnCall.people())
    assert asked() == 1
  end

  test "while another lookup holds on, the rest give up and fall back" do
    pagerduty([user("ada@example.test")])
    test = self()

    holder =
      spawn(fn ->
        :global.set_lock({OnCall, self()}, [node()], 0)
        send(test, :held)
        Process.sleep(:infinity)
      end)

    assert_receive :held
    assert OnCall.people() == :none
    Process.exit(holder, :kill)
    assert asked() == 0
  end

  test "the lookup at send time is quick: no retries and a short wait" do
    assert OnCall.quick()[:retry] == false
    assert OnCall.quick()[:receive_timeout] <= 3_000
  end

  test "on call stands alone", %{ada: ada} do
    assert {:error, "oncall stands alone."} = People.set_who("default", "", ["oncall", ada.id])
    assert People.audience([]) == :everyone
    People.set_who("default", "", ["oncall"])
    assert People.audience([]) == :oncall
  end

  test "a person with no email does not trip the matching" do
    pagerduty([user("cy@example.test")])
    assert OnCall.people() == :none
    assert Repo.exists?(from u in Dokkit.User, where: u.name == "cy")
  end
end
