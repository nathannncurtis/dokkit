defmodule Dokkit.OnCallTest do
  use Dokkit.DataCase, async: false
  alias Dokkit.{Accounts, Alerts, Intake, Keys, Machine, OnCall, People, Repo, Service}

  setup do
    machine = Repo.insert!(%Machine{name: "vault"})

    service =
      Repo.insert!(%Service{machine_id: machine.id, slug: "backup", name: "Backup", kind: :job})

    {_, key} = Keys.mint(:app, %{service_id: service.id})
    {:ok, ada} = Accounts.add("ada", "member", "a long enough password")
    People.update(ada.id, %{"pagerduty_key" => "ADA-KEY", "email" => "Ada@Example.test"})

    Alerts.save(%{
      "pagerduty_key" => "TEAM-KEY",
      "pagerduty_api_key" => "REST-#{System.unique_integer([:positive])}",
      "pagerduty_schedule" => "PSCHED1"
    })

    %{key: key, service: service, ada: ada}
  end

  defp pagerduty(oncall_email, status \\ 200) do
    test = self()

    Req.Test.stub(Alerts, fn conn ->
      case {conn.host, conn.request_path} do
        {"api.pagerduty.com", path} ->
          send(
            test,
            {:rest, path, conn.query_string, Plug.Conn.get_req_header(conn, "authorization")}
          )

          body =
            if path == "/schedules",
              do: %{"schedules" => [%{"id" => "PSCHED1", "name" => "Primary"}]},
              else: %{
                "oncalls" => [
                  %{
                    "escalation_level" => 1,
                    "user" => %{"name" => "Ada L", "email" => oncall_email}
                  }
                ]
              }

          conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

        {"events.pagerduty.com", _} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          e = Jason.decode!(body)
          send(test, {:paged, e["routing_key"], e["event_action"]})
          Plug.Conn.send_resp(conn, 202, "{}")
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
      {:rest, "/oncalls", _, _} -> 1 + asked()
    after
      0 -> 0
    end
  end

  test "lists the schedules and who is on call, with the REST key", %{ada: ada} do
    pagerduty("ada@example.test")
    config = Alerts.config()
    assert {:ok, [%{id: "PSCHED1", name: "Primary"}]} = OnCall.schedules()
    assert_received {:rest, "/schedules", _, ["Token token=" <> rest]}
    assert rest == config["pagerduty_api_key"]

    view = OnCall.view()
    assert view.oncall.email == "ada@example.test"
    assert view.oncall.person.id == ada.id
    assert_received {:rest, "/oncalls", query, _}
    assert URI.decode_query(query)["schedule_ids[]"] == "PSCHED1"
    assert Alerts.view()["pagerduty_api_key"] == "set"
  end

  test "the person on call is paged on their own key, and resolved there", %{
    key: key,
    service: service
  } do
    pagerduty("ada@example.test")
    assert {:ok, _} = People.set_who("service", service.id, ["oncall"])

    Intake.ping(key, "backup", "fail", nil, "")
    Alerts.deliver_pending()
    assert paged() == [{"ADA-KEY", "trigger"}]

    Intake.ping(key, "backup", "ok", nil, "")
    Alerts.deliver_pending()
    assert paged() == [{"ADA-KEY", "resolve"}]
  end

  test "nobody here with that email: the server-wide key is paged", %{key: key} do
    pagerduty("someone@else.test")
    People.set_who("default", "", ["oncall"])
    Intake.ping(key, "backup", "fail", nil, "")
    Alerts.deliver_pending()
    assert paged() == [{"TEAM-KEY", "trigger"}]
  end

  test "PagerDuty cannot be reached: the server-wide key is paged", %{key: key} do
    pagerduty("ada@example.test", 500)
    People.set_who("default", "", ["oncall"])
    Intake.ping(key, "backup", "fail", nil, "")
    Alerts.deliver_pending()
    assert paged() == [{"TEAM-KEY", "trigger"}]
    assert OnCall.view().error
  end

  test "a burst of lookups asks PagerDuty once" do
    pagerduty("ada@example.test")
    for _ <- 1..5, do: assert({:ok, _} = OnCall.person())
    assert asked() == 1
  end

  test "on call stands alone", %{ada: ada} do
    assert {:error, "oncall stands alone."} = People.set_who("default", "", ["oncall", ada.id])
    assert People.audience([]) == :everyone
    People.set_who("default", "", ["oncall"])
    assert People.audience([]) == :oncall
  end
end
