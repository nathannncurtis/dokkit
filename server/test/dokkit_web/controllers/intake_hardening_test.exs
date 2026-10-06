defmodule DokkitWeb.IntakeHardeningTest do
  use DokkitWeb.ConnCase, async: true
  alias Dokkit.{Batch, Check, JobRun, Keys, Log, Machine, RateLimit, Repo, Service}

  setup do
    machine = Repo.insert!(%Machine{name: "hard-box"})
    service = Repo.insert!(%Service{machine_id: machine.id, slug: "hard-svc", name: "Hard"})
    {app, appkey} = Keys.mint(:app, %{service_id: service.id})
    {mkey, _} = Keys.mint(:machine, %{machine_id: machine.id})
    %{machine: machine, service: service, app: app, appkey: appkey, mkey: mkey}
  end

  test "one bad line is refused and the rest of the batch is stored", %{mkey: mkey} do
    lines = [
      %{type: "job", service: "hard-svc", run: "big", event: "ok", exit_code: 4_294_967_295},
      %{type: "job", service: "hard-svc", run: "huge", event: "ok", exit_code: 10 ** 30},
      %{type: "log", msg: "a\u0000b", fields: %{"k\u0000" => "v\u0000"}},
      %{type: "job", service: "hard-svc", run: "tail", event: "ok", tail: "x\u0000y"}
    ]

    answer = json_response(report(mkey, lines), 200)
    assert %{"accepted" => 3, "refused" => [%{"line" => 2, "code" => "bad_line"}]} = answer
    assert Repo.get_by!(JobRun, run: "big").exit_code == 4_294_967_295
    assert Repo.get_by!(JobRun, run: "tail").tail == "xy"
    assert Repo.get_by!(Log, msg: "ab").fields == %{"k" => "v"}
  end

  test "an app key cannot keep an enrolled machine looking alive", %{app: app} do
    old = ~U[2026-01-01 00:00:00.000000Z]
    enrolled = Repo.insert!(%Machine{name: "hard-enrolled", last_seen_at: old})
    seen = Repo.insert!(%Machine{name: "hard-seen", kind: :seen, last_seen_at: old})

    for host <- ["hard-enrolled", "hard-seen"],
        do: report(app, [%{type: "custom", check: "c", state: "ok", host: host}])

    assert Repo.get!(Machine, enrolled.id).last_seen_at == old
    assert DateTime.compare(Repo.get!(Machine, seen.id).last_seen_at, old) == :gt
  end

  test "a key that has used up its quota is answered 429", %{app: app, appkey: appkey} do
    assert :ok = RateLimit.take(appkey.id, 10_000)
    conn = report(app, [%{type: "log", msg: "x"}])
    assert json_response(conn, 429)["error"]["code"] == "rate_limited"
    assert [wait] = get_resp_header(conn, "retry-after")
    assert String.to_integer(wait) >= 1
  end

  test "the bucket refills with time" do
    id = Ecto.UUID.generate()
    assert :ok = RateLimit.take(id, 10_000, 0)
    assert {:wait, 1} = RateLimit.take(id, 100, 0)
    assert :ok = RateLimit.take(id, 100, 1000)
  end

  test "an app key stops making checks at the cap", %{app: app, service: service} do
    for n <- 1..100,
        do: Repo.insert!(%Check{service_id: service.id, name: "c#{n}", type: :custom})

    answer =
      report(app, [%{type: "custom", check: "one-more", state: "ok"}]) |> json_response(200)

    assert [%{"code" => "too_many_checks"}] = answer["refused"]
  end

  test "log fields over the cap are dropped and the line marked cut", %{mkey: mkey} do
    fields = %{"blob" => String.duplicate("x", 70_000)}
    report(mkey, [%{type: "log", msg: "fat", fields: fields}])
    assert %Log{fields: %{}, cut: true} = Repo.get_by!(Log, msg: "fat")
  end

  test "the same batch id from two keys is kept for each", %{mkey: mkey, app: app} do
    id = Ecto.UUID.generate()
    line = %{type: "log", msg: "same first line"}
    assert json_response(report(mkey, [line], [{"dokkit-batch", id}]), 200)["accepted"] == 1
    assert json_response(report(app, [line, line], [{"dokkit-batch", id}]), 200)["accepted"] == 2
    assert Repo.aggregate(Batch, :count) >= 2
  end

  test "an envelope with no good key is refused before it is inflated" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/x-ndjson")
      |> put_req_header("content-encoding", "gzip")
      |> post("/api/hard-project/envelope", "not gzip at all")

    assert json_response(conn, 401)
  end

  test "bad gzip on the report door answers 413", %{mkey: mkey} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> mkey)
      |> put_req_header("content-type", "application/x-ndjson")
      |> put_req_header("content-encoding", "gzip")
      |> post("/api/v1/report", "not gzip at all")

    assert json_response(conn, 413)
  end

  test "a log line without msg is kept whole as its message", %{mkey: mkey} do
    report(mkey, [%{type: "log", message: "disk low", level: "warn"}])
    assert %Log{msg: msg} = Repo.get_by!(Log, level: "warn")
    assert msg =~ "disk low"
  end

  test "a log line's own time is kept and received_at is the server's", %{mkey: mkey} do
    hour_ago = DateTime.add(DateTime.utc_now(), -3600)
    report(mkey, [%{type: "log", msg: "skewed", at: DateTime.to_iso8601(hour_ago)}])
    log = Repo.get_by!(Log, msg: "skewed")
    assert_in_delta DateTime.diff(log.received_at, log.at), 3600, 5
  end

  test "a ping body that is not valid form data still reaches the controller", %{app: app} do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post("/api/v1/in/#{app}/job/hardjob/fail?run=hp1", "100% done \xff\u0000 end")

    assert json_response(conn, 200)
    assert Repo.get_by!(JobRun, run: "hp1").tail == "100% done  end"
  end

  describe "enrolling" do
    defp token, do: elem(Keys.mint(:enrol), 0)

    test "a name that is already enrolled is refused unless replacing", %{conn: conn} do
      body = fn token, extra ->
        Map.merge(%{token: token, hostname: "hard-enrol-host", os: "linux"}, extra)
      end

      first = token()
      assert %{"key" => old} = json_response(post(conn, "/api/v1/enrol", body.(first, %{})), 200)

      second = token()
      assert json_response(post(build_conn(), "/api/v1/enrol", body.(second, %{})), 409)
      assert json_response(get(authed(old), "/api/v1/ping"), 200)

      # The refused token was not spent.
      assert %{"key" => new} =
               json_response(
                 post(build_conn(), "/api/v1/enrol", body.(second, %{replace: true})),
                 200
               )

      assert json_response(get(authed(old), "/api/v1/ping"), 401)
      assert json_response(get(authed(new), "/api/v1/ping"), 200)
    end

    defp authed(key), do: put_req_header(build_conn(), "authorization", "Bearer " <> key)
  end
end
