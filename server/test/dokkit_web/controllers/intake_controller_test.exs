defmodule DokkitWeb.IntakeControllerTest do
  use DokkitWeb.ConnCase, async: true
  alias Dokkit.{Issue, Issues, JobRun, Keys, Machine, Repo, Service}

  setup do
    machine = Repo.insert!(%Machine{name: "vault"})

    service =
      Repo.insert!(%Service{
        machine_id: machine.id,
        slug: "backup",
        name: "Nightly backup",
        kind: :job
      })

    {app, _} = Keys.mint(:app, %{service_id: service.id})
    {mkey, _} = Keys.mint(:machine, %{machine_id: machine.id})
    %{service: service, app: app, mkey: mkey}
  end

  defp report(conn, key, lines, headers \\ []) do
    body = Enum.map_join(lines, "\n", &Jason.encode!/1)

    Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    |> put_req_header("authorization", "Bearer " <> key)
    |> put_req_header("content-type", "application/x-ndjson")
    |> post("/api/v1/report", body)
  end

  test "a ping records a run; a failed one opens an issue and a good one closes it", %{
    conn: conn,
    app: app,
    service: service
  } do
    assert json_response(get(conn, "/api/v1/in/#{app}/job/backup/start?run=r1"), 200)
    assert %JobRun{result: :running} = Repo.get_by!(JobRun, run: "r1")

    conn2 =
      conn
      |> put_req_header("content-type", "text/plain")
      |> post("/api/v1/in/#{app}/job/backup/fail?run=r1", "disk full")

    assert json_response(conn2, 200)
    assert %JobRun{result: :fail, tail: "disk full"} = Repo.get_by!(JobRun, run: "r1")
    assert [%Issue{title: "Nightly backup failed", count: 1} = issue] = Issues.open_list()
    assert Issue.short_id(issue) =~ ~r/^DOK-\d+$/
    assert Repo.get!(Service, service.id).state == :down

    get(conn, "/api/v1/in/#{app}/job/backup/ok")
    assert Issues.open_list() == []
    assert Repo.get!(Service, service.id).state == :ok

    get(conn, "/api/v1/in/#{app}/job/backup/fail")
    assert [%Issue{count: 2, id: id}] = Issues.open_list()
    assert id == issue.id
  end

  test "a bad key is refused", %{conn: conn} do
    assert json_response(get(conn, "/api/v1/in/dka_nope/job/backup/ok"), 401)
    assert json_response(report(conn, "dkm_nope", []), 401)
  end

  test "a report takes good lines, refuses bad ones, and is stored once", %{
    conn: conn,
    mkey: mkey
  } do
    lines = [
      %{type: "job", service: "backup", run: "a", event: "start", at: "2026-10-06T01:00:00Z"},
      %{type: "job", service: "backup", run: "a", event: "ok", duration_ms: 1200},
      %{type: "job", service: "nothing", event: "ok"},
      %{type: "wat"}
    ]

    batch = Ecto.UUID.generate()
    answer = json_response(report(conn, mkey, lines, [{"dokkit-batch", batch}]), 200)
    assert answer["accepted"] == 2

    assert [%{"line" => 3, "code" => "unknown_service"}, %{"line" => 4, "code" => "unknown_type"}] =
             answer["refused"]

    assert %JobRun{result: :ok, duration_ms: 1200} = Repo.get_by!(JobRun, run: "a")

    assert json_response(report(conn, mkey, lines, [{"dokkit-batch", batch}]), 200) == answer
    assert Repo.aggregate(JobRun, :count) == 1
  end

  test "a check opens an issue after three failures in a row", %{conn: conn, mkey: mkey} do
    bad = %{type: "state", service: "backup", check: "http", state: "down"}
    report(conn, mkey, [bad, bad])
    assert Issues.open_list() == []
    report(conn, mkey, [bad])
    assert [%Issue{state: :down}] = Issues.open_list()
  end

  test "gzip is accepted and an app key may not send state", %{conn: conn, app: app} do
    body = :zlib.gzip(Jason.encode!(%{type: "state", check: "x", state: "ok"}))

    answer =
      conn
      |> put_req_header("authorization", "Bearer " <> app)
      |> put_req_header("content-type", "application/x-ndjson")
      |> put_req_header("content-encoding", "gzip")
      |> post("/api/v1/report", body)
      |> json_response(200)

    assert [%{"code" => "not_allowed"}] = answer["refused"]
  end

  test "what the dokkit program sends for a wrapped job", %{conn: conn, app: app} do
    run = Ecto.UUID.generate()

    lines = [
      %{
        type: "job",
        name: "backup",
        run: run,
        event: "start",
        at: "2026-10-06T01:00:00.123456789Z"
      },
      %{
        type: "job",
        name: "backup",
        run: run,
        event: "fail",
        exit_code: 3,
        duration_ms: 2100,
        tail: "copying
rsync: disk full
"
      }
    ]

    body = :zlib.gzip(Enum.map_join(lines, "
", &Jason.encode!/1) <> "
")

    answer =
      conn
      |> put_req_header("authorization", "Bearer " <> app)
      |> put_req_header("content-type", "application/x-ndjson")
      |> put_req_header("content-encoding", "gzip")
      |> put_req_header("dokkit-batch", Ecto.UUID.generate())
      |> post("/api/v1/report", body)
      |> json_response(200)

    assert answer == %{"accepted" => 2, "refused" => []}

    assert %JobRun{result: :fail, exit_code: 3, duration_ms: 2100} =
             Repo.get_by!(JobRun, run: run)

    assert [%Issue{title: "Nightly backup failed", check: %{note: "rsync: disk full"}}] =
             Issues.open_list()
  end

  test "ping answers a known key with the time", %{conn: conn, app: app} do
    assert %{"ok" => true, "time" => _} =
             conn
             |> put_req_header("authorization", "Bearer " <> app)
             |> get("/api/v1/ping")
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/ping"), 401)
  end
end
