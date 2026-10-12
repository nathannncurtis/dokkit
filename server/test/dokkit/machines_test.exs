defmodule Dokkit.MachinesTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Dokkit.{Alert, Alerts, Estate, Issues, Machine, Repo}

  setup do
    Req.Test.stub(Alerts, fn conn -> Plug.Conn.send_resp(conn, 202, "{}") end)
    :ok
  end

  test "a machine enrols once, reports, goes quiet, and comes back", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn), "/machines/new")
    html = render_click(view, "token")
    [token] = Regex.run(~r/dke_\w+/, html)

    body = %{token: token, hostname: "press01", os: "windows", arch: "amd64", dokkit: "0.1.0"}

    assert %{"key" => "dkm_" <> _ = key, "machine" => id} =
             json_response(post(build_conn(), "/api/v1/enrol", body), 200)

    assert json_response(post(build_conn(), "/api/v1/enrol", body), 401)

    assert %Machine{kind: :enrolled, os: "windows", program_version: "0.1.0"} =
             Repo.get!(Machine, id)

    assert %{"accepted" => 1} =
             report(key, [%{type: "inventory", os: "windows", dokkit: "0.1.1"}])
             |> json_response(200)

    assert Repo.get!(Machine, id).program_version == "0.1.1"

    {:ok, job} = Estate.add_job(%{"name" => "Proofs", "machine" => "press01"})
    now = DateTime.utc_now()
    assert Issues.machines_sweep(now) == 0
    later = DateTime.add(now, 200)
    assert Issues.machines_sweep(later) == 1
    assert Issues.machines_sweep(later) == 0

    assert [
             %{
               title: "press01 stopped reporting",
               kind: "machine",
               alerts: [%Alert{channel: "page"}]
             }
           ] = Issues.open_list()

    # What runs on a machine that is down opens its issue without alerting.
    post(build_conn(), "/api/v1/in/#{job.key}/job/proofs/fail")

    assert [%{kind: "job", alerts: []}, %{kind: "machine"}] =
             Enum.sort_by(Issues.open_list(), & &1.kind)

    {:ok, _, html} = live(signed_in(conn), "/")
    assert html =~ "press01 stopped reporting"
    {:ok, _, html} = live(signed_in(conn), "/all")
    assert html =~ "Stopped reporting"

    report(key, [%{type: "inventory"}])
    assert Issues.machines_sweep(DateTime.utc_now()) == 1
    assert [%{kind: "job"}] = Issues.open_list()
    refute Issues.machine_down?(id)
  end

  test "a machine that only has pinged jobs is never called down" do
    {:ok, _} = Estate.add_job(%{"name" => "Purge", "machine" => "nas"})
    assert Issues.machines_sweep(DateTime.add(DateTime.utc_now(), 86_400)) == 0
  end
end
