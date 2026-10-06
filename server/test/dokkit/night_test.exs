defmodule Dokkit.NightTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Dokkit.{Alert, Alerts, Check, Estate, Issues, Machine, Repo, Service}

  @late ~U[2026-01-10 23:30:00.000000Z]
  @morning ~U[2026-01-11 07:05:00.000000Z]
  @noon ~U[2026-01-10 12:00:00.000000Z]

  setup do
    Alerts.save(%{"pagerduty_key" => "K", "night_from" => "22", "night_to" => "7"})
    test = self()

    Req.Test.stub(Alerts, fn conn ->
      send(test, :sent)
      Plug.Conn.send_resp(conn, 202, "{}")
    end)

    :ok
  end

  defp job(name, night, route \\ nil) do
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

  defp fail(check, at) do
    Issues.record(check, :down, at: at, title: "#{check.name} failed")
    issue = Repo.get_by!(Dokkit.Issue, check_id: check.id)
    {issue, Repo.get_by!(Alert, issue_id: issue.id)}
  end

  test "the night is hours from UTC and may cross midnight" do
    assert Alerts.night?(@late)
    assert Alerts.night?(~U[2026-01-11 06:59:00Z])
    refute Alerts.night?(@morning)
    refute Alerts.night?(@noon)
    assert Alerts.night?(@noon, %{"night_from" => "9", "night_to" => "17", "night_offset" => "0"})

    assert Alerts.night?(@noon, %{"night_from" => "22", "night_to" => "7", "night_offset" => "-6"})

    assert Alerts.night_error(%{"night_from" => "25"})
    assert Alerts.night_error(%{"night_offset" => "x"})
    refute Alerts.night_error(%{"night_from" => "21", "night_offset" => "-5"})
  end

  test "an alert for a service that does not wake you is held, then sent after the night" do
    {issue, alert} = fail(job("held-a", false), @late)
    assert alert.status == :held
    assert Alerts.deliver_pending() == 0

    assert Alerts.release(@late) == 0
    assert Repo.reload!(alert).status == :held

    assert Alerts.release(@morning) == 1
    assert Alerts.deliver_pending() == 1
    assert_received :sent
    assert Repo.reload!(alert).status == :sent
    assert Alerts.release(@morning) == 0
    assert issue
  end

  test "a held alert is dropped when its issue closed in the night" do
    check = job("held-b", false)
    {_, alert} = fail(check, @late)
    Issues.record(Repo.reload!(check), :ok, at: ~U[2026-01-11 01:00:00.000000Z])
    assert Repo.reload!(alert).status == :skipped
    assert Alerts.release(@morning) == 0
    assert Alerts.deliver_pending() == 0
    refute_received :sent
  end

  test "a service that wakes you is alerted at once, and nothing is held by day" do
    {_, a} = fail(job("held-c", true), @late)
    assert a.status == :pending
    {_, b} = fail(job("held-d", false), @noon)
    assert b.status == :pending
    assert Alerts.deliver_pending() == 2
  end

  test "the digest is not held" do
    {_, alert} = fail(job("held-e", false, "digest"), @late)
    assert alert.status == :pending
  end

  test "the routing form saves the switch and the API accepts it" do
    check = job("held-f", true)
    service = Repo.get!(Service, check.service_id)
    {:ok, view, html} = live(signed_in(build_conn()), "/s/#{service.id}")
    assert html =~ "Wake me at night for this"

    view |> form("#route-form", route: %{night: false}) |> render_change()
    refute Repo.reload!(service).night
    view |> form("#route-form", route: %{night: true}) |> render_change()
    assert Repo.reload!(service).night

    assert %{night: false} =
             DokkitWeb.ApiController.set_routing(%{"id" => service.id, "night" => false})

    refute Repo.reload!(service).night

    assert %{night: true} =
             DokkitWeb.ApiController.set_routing(%{"id" => service.id, "night" => "true"})
  end

  test "an interface job's timing can be edited, a file job's cannot" do
    {:ok, %{service: service}} =
      Estate.add_job(%{"name" => "Purge", "machine" => "nas", "grace" => "30m"})

    {:ok, view, html} = live(signed_in(build_conn()), "/s/#{service.id}")
    assert html =~ "Count it as late after"

    bad = view |> form("#timing-form", timing: %{grace: "soon"}) |> render_submit()
    assert bad =~ "Write times as a number and a unit"

    view |> form("#timing-form", timing: %{grace: "45m", max_runtime: "2h"}) |> render_submit()
    check = Repo.get_by!(Check, service_id: service.id)
    assert %{"grace" => "45m", "max_runtime" => "2h"} = check.config

    view |> form("#timing-form", timing: %{grace: "", max_runtime: ""}) |> render_submit()
    assert Repo.reload!(check).config == %{}

    Repo.update!(Ecto.Changeset.change(check, source: :file, config: %{"grace" => "10m"}))

    assert {:error, "Set in its dokkit.toml."} =
             Estate.set_job_timing(Repo.reload!(check), %{"grace" => "5m"})

    {:ok, _, html} = live(signed_in(build_conn()), "/s/#{service.id}")
    assert html =~ "Set in its dokkit.toml."
    refute html =~ "timing-form"
  end
end
