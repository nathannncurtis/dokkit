defmodule Dokkit.FoundJobsTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias Dokkit.{Check, Found, Keys, Machine, Repo, Service, WorkRun}

  setup do
    machine = Repo.insert!(%Machine{name: "ops-box", kind: :enrolled})
    {key, _} = Keys.mint(:machine, %{machine_id: machine.id})

    %{
      machine: machine,
      key: key,
      as: put_req_header(build_conn(), "authorization", "Bearer " <> key)
    }
  end

  @note "Task Scheduler lists only the tasks this account is allowed to read."

  defp proposal do
    %{
      os: "windows",
      notes: [@note],
      found: %{
        jobs: [
          %{
            name: "Nightly export",
            source: "task-scheduler",
            record: "record",
            unit: "\\Nightly export",
            schedule: "0 8 * * *",
            schedule_note:
              "Read in UTC: converted from this machine's local time, -4 hours from UTC now.",
            last_run: "2026-10-11T08:00:01Z",
            last_result: "ok",
            command: "C:\\tools\\export.exe --all"
          },
          %{
            name: "backup",
            source: "cron",
            record: "wrapper",
            schedule: "15 3 * * *",
            command: "/usr/local/bin/backup.sh"
          },
          %{
            name: "At logon thing",
            source: "task-scheduler",
            record: "record",
            unit: "\\Logon",
            schedule: "",
            schedule_note: "Runs at logon time, which is not a time of day."
          },
          %{name: "Bad", source: "cron", schedule: "99 99 * * *", command: "x"}
        ],
        containers: [
          %{name: "db", image: "postgres:17", port: "5432"},
          %{name: "worker", image: "app:1", port: ""}
        ],
        sites: [
          %{name: "Portal", server: "iis", url: "https://portal.example.com/", state: "started"},
          %{name: "Stopped", server: "iis", url: "http://localhost/", state: "stopped"},
          %{name: "NoAddress", server: "nginx"}
        ]
      }
    }
  end

  test "jobs, containers with a port and sites with an address are kept", %{as: as} do
    assert json_response(post(as, "/api/v1/proposals", proposal()), 200) == %{"waiting" => 6}
    kinds = Enum.frequencies(Enum.map(Found.list(), & &1.kind))
    assert kinds == %{"job" => 4, "container" => 1, "site" => 1}

    bad = Enum.find(Found.list(), &(&1.key == "bad"))
    assert bad.detail["schedule"] == nil
    assert bad.detail["schedule_note"] == "Its schedule could not be read."
  end

  test "an accepted job waits for its first report; its runs are read from the system's record or wrapped",
       %{as: as, key: key, machine: machine} do
    post(as, "/api/v1/proposals", proposal())
    all = Found.list()
    export = Enum.find(all, &(&1.key == "nightly-export"))
    backup = Enum.find(all, &(&1.key == "backup"))
    db = Enum.find(all, &(&1.kind == "container"))
    site = Enum.find(all, &(&1.kind == "site"))
    Found.watch([export.id, backup.id, db.id, site.id])

    export_check = check(machine, "nightly-export")
    assert export_check.type == :job
    assert export_check.config["waiting"] == true
    assert export_check.config["schedule"] == "0 8 * * *"
    assert export_check.fail_after == 1
    assert Repo.get_by!(Service, machine_id: machine.id, slug: "nightly-export").kind == :job
    assert check(machine, "backup").config == %{"waiting" => true, "schedule" => "15 3 * * *"}

    assert %{
             "items" => [
               %{
                 "service" => "nightly-export",
                 "name" => "nightly-export",
                 "source" => "task-scheduler",
                 "unit" => "\\Nightly export"
               }
             ]
           } =
             json_response(get(as, "/api/v1/records"), 200)

    items = json_response(get(as, "/api/v1/checks"), 200)["items"]

    assert %{"config" => %{"port" => 5432}, "type" => "tcp"} =
             Enum.find(items, &(&1["service"] == "container-db"))

    assert %{"config" => %{"url" => "https://portal.example.com/"}, "type" => "http"} =
             Enum.find(items, &(&1["service"] == "site-portal"))

    report(key, [
      %{
        type: "job",
        service: "nightly-export",
        name: "nightly-export",
        event: "ok",
        exit_code: 0,
        at: DateTime.to_iso8601(DateTime.utc_now())
      }
    ])

    refute check(machine, "nightly-export").config["waiting"]

    post(as, "/api/v1/proposals", proposal())

    refute Enum.any?(Found.list(), &(&1.key in ["nightly-export", "backup"])),
           "a watched job is not offered again"
  end

  test "the page says how each found job is watched, with the line to copy", %{conn: conn, as: as} do
    post(as, "/api/v1/proposals", proposal())
    {:ok, _view, html} = live(signed_in(conn), "/found")
    assert html =~ "Watched from this machine&#39;s own record"
    assert html =~ "Needs the wrapper"
    assert html =~ "dokkit run --job backup -- /usr/local/bin/backup.sh"
    assert html =~ "dokkit ping backup ok"
    assert html =~ "No schedule Dokkit can read"
    assert html =~ @note
    assert html =~ "Scheduled task"
    assert html =~ "Cron entry"
    assert html =~ "Container"
    assert html =~ "Web site"
  end

  test "Look again queues the built-in scan, and the page says what came of it", %{
    conn: conn,
    machine: machine
  } do
    {:ok, view, html} = live(signed_in(conn), "/found")
    assert html =~ "ops-box"
    refute html =~ "too old"

    render_click(view, "scan", %{"id" => machine.id})
    run = Repo.one!(from r in WorkRun, where: r.machine_id == ^machine.id)
    assert run.name == "dokkit:scan" and run.state == :queued and run.payload == nil
    assert render(view) =~ "Waiting for the machine to take it"

    Repo.update_all(from(r in WorkRun, where: r.id == ^run.id),
      set: [state: :refused, output: "This program does not run that."]
    )

    {:ok, _view, html} = live(signed_in(conn), "/found")
    assert html =~ "This machine&#39;s program is too old to be asked."
  end

  test "the scan is asked for through the API, as a member may", %{machine: machine} do
    {member, _} = Keys.mint(:user, %{scopes: ["read", "act"]})
    {viewer, _} = Keys.mint(:user, %{scopes: ["read"]})
    seen = Repo.insert!(%Machine{name: "app-host", kind: :seen})

    call = fn token, id ->
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/v1/machines/#{id}/scan")
    end

    assert json_response(call.(viewer, machine.id), 403)
    assert %{"run" => run} = json_response(call.(member, machine.id), 200)
    assert Repo.get!(WorkRun, run).name == "dokkit:scan"
    assert json_response(call.(member, seen.id), 404)
  end

  defp check(machine, name) do
    Repo.one!(
      from c in Check,
        join: s in assoc(c, :service),
        where: s.machine_id == ^machine.id and c.name == ^name
    )
  end
end
