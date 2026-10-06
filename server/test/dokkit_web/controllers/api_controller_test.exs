defmodule DokkitWeb.ApiControllerTest do
  use DokkitWeb.ConnCase, async: true
  alias Dokkit.{Estate, Issues, Keys}

  setup do
    {:ok, job} =
      Estate.add_job(%{"name" => "Nightly backup", "machine" => "nas", "schedule" => "0 1 * * *"})

    post(
      build_conn() |> put_req_header("content-type", "text/plain"),
      "/api/v1/in/#{job.key}/job/nightly-backup/fail",
      "disk full"
    )

    report(job.key, [%{type: "log", level: "error", msg: "rsync: disk full"}])

    {read, _} = Keys.mint(:user, %{scopes: ["read"]})
    {all, _} = Keys.mint(:user, %{scopes: ["read", "read-logs", "act"]})
    {ops, _} = Keys.mint(:user, %{scopes: ["admin"]})
    %{job: job, read: read, all: all, ops: ops}
  end

  defp call(method, path, token, body \\ %{}) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> dispatch(@endpoint, method, "/api/v1" <> path, body)
  end

  test "a read token reads everything but log contents, and cannot act", %{job: job, read: read} do
    assert %{"needs_you" => [issue], "snoozed" => []} =
             json_response(call(:get, "/inbox", read), 200)

    assert %{
             "title" => "Nightly backup failed",
             "note" => "disk full",
             "machine" => "nas",
             "short_id" => "DOK-" <> _
           } = issue

    assert %{"items" => [%{"name" => "nas", "needs_a_look" => 1}], "next" => nil} =
             json_response(call(:get, "/machines", read), 200)

    assert %{"items" => [%{"slug" => "nightly-backup", "state" => "down"}]} =
             json_response(call(:get, "/services?q=BACKUP", read), 200)

    assert %{"items" => []} = json_response(call(:get, "/services?q=nothing", read), 200)

    id = job.service.id

    assert %{"checks" => [%{"type" => "job"}], "open_issue" => %{"kind" => "job"}} =
             json_response(call(:get, "/services/#{id}", read), 200)

    assert %{
             "items" => [
               %{
                 "schedule" => "0 1 * * *",
                 "last_run" => %{"result" => "fail"},
                 "next_expected" => next
               }
             ]
           } = json_response(call(:get, "/jobs", read), 200)

    assert is_binary(next)

    assert %{"items" => [run]} = json_response(call(:get, "/jobs/#{id}/runs", read), 200)
    refute Map.has_key?(run, "tail")

    assert %{"items" => [_]} = json_response(call(:get, "/issues", read), 200)

    assert json_response(call(:get, "/logs", read), 403)["error"]["code"] == "no_scope"
    assert json_response(call(:put, "/rules/x", read, %{}), 403)
    assert json_response(call(:post, "/issues/#{issue["id"]}/acknowledge", read), 403)
    assert json_response(call(:get, "/services/nope", read), 404)
    assert json_response(call(:get, "/inbox", job.key), 401)
    assert json_response(call(:get, "/inbox", "dku_nope"), 401)
  end

  test "a token with read-logs sees job output and issue notes", %{job: job, all: all} do
    id = job.service.id

    assert %{"items" => [%{"tail" => "disk full"}]} =
             json_response(call(:get, "/jobs/#{id}/runs", all), 200)

    [issue] = Issues.open_list()
    Issues.note(issue.id, "Disk swapped", "sam")
    assert %{"notes" => [_]} = json_response(call(:get, "/issues/#{issue.id}", all), 200)
  end

  test "an unknown issue is not found when snoozed, unsnoozed or acknowledged", %{all: all} do
    id = Ecto.UUID.generate()
    until = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
    assert json_response(call(:post, "/issues/#{id}/snooze", all, %{until: until}), 404)
    assert json_response(call(:post, "/issues/#{id}/unsnooze", all), 404)
    assert json_response(call(:post, "/issues/#{id}/acknowledge", all), 404)
    assert json_response(call(:post, "/issues/nope/acknowledge", all), 404)
  end

  test "logs are filtered by machine and by time", %{all: all} do
    assert %{"items" => [_]} = json_response(call(:get, "/logs?machine=nas", all), 200)

    assert %{"items" => []} =
             json_response(call(:get, "/logs?from=2999-01-01T00:00:00Z", all), 200)

    assert %{"items" => [_]} =
             json_response(call(:get, "/logs?to=2999-01-01T00:00:00Z", all), 200)

    assert %{"items" => []} = json_response(call(:get, "/logs?to=2000-01-01T00:00:00Z", all), 200)
    assert json_response(call(:get, "/logs?machine=nowhere", all), 404)
    assert json_response(call(:get, "/logs?from=yesterday", all), 404)
  end

  test "a token with more reads logs and acts", %{all: all} do
    assert %{
             "items" => [
               %{"msg" => "rsync: disk full", "level" => "error", "service" => "nightly-backup"}
             ]
           } = json_response(call(:get, "/logs?q=rsync", all), 200)

    [issue] = Issues.open_list()
    assert json_response(call(:post, "/issues/#{issue.id}/acknowledge", all), 200)

    assert json_response(
             call(:post, "/issues/#{issue.id}/snooze", all, %{until: "2020-01-01T00:00:00Z"}),
             422
           )

    until = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
    assert json_response(call(:post, "/issues/#{issue.id}/snooze", all, %{until: until}), 200)

    assert %{"needs_you" => [], "snoozed" => [%{"acknowledged_at" => seen}]} =
             json_response(call(:get, "/inbox", all), 200)

    assert seen
    assert json_response(call(:post, "/issues/#{issue.id}/unsnooze", all), 200)
    assert Issues.open_count() == 1
  end

  test "notes, bulk actions, routing, rules, one machine and versions", %{
    job: job,
    read: read,
    all: all,
    ops: ops
  } do
    %{"needs_you" => [%{"id" => id, "service" => service}]} =
      json_response(call(:get, "/inbox", read), 200)

    assert json_response(call(:post, "/issues/#{id}/notes", read, %{text: "x"}), 403)
    assert json_response(call(:post, "/issues/#{id}/notes", all, %{}), 422)
    assert json_response(call(:post, "/issues/#{id}/notes", all, %{text: "Disk swapped"}), 200)

    assert %{"notes" => [%{"text" => "Disk swapped", "by" => "token " <> _}], "closed_at" => nil} =
             json_response(call(:get, "/issues/#{id}", all), 200)

    assert json_response(call(:get, "/issues/nope", read), 404)

    assert json_response(call(:post, "/issues/bulk", all, %{ids: [id], action: "snooze"}), 422)

    assert json_response(
             call(:post, "/issues/bulk", all, %{ids: [id], action: "acknowledge"}),
             200
           )

    until = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))

    assert json_response(
             call(:post, "/issues/bulk", all, %{ids: [id], action: "snooze", until: until}),
             200
           )

    assert %{"needs_you" => [], "snoozed" => [%{"acknowledged_at" => at}]} =
             json_response(call(:get, "/inbox", read), 200)

    assert at

    assert %{"down" => "email", "degraded" => nil} =
             json_response(
               call(:put, "/services/#{service}/routing", all, %{
                 down: "email",
                 degraded: "pigeon"
               }),
               200
             )

    assert %{"id" => rule, "channel" => "push", "on" => true} =
             json_response(call(:post, "/rules", ops, %{kind: "job", channel: "push"}), 200)

    assert %{"channel" => "email", "on" => false, "kind" => "job"} =
             json_response(
               call(:put, "/rules/#{rule}", ops, %{kind: "job", channel: "email", on: false}),
               200
             )

    assert json_response(call(:put, "/rules/nope", ops, %{}), 404)
    assert json_response(call(:delete, "/rules/#{rule}", ops), 200)
    assert %{"items" => []} = json_response(call(:get, "/rules", read), 200)

    %{"items" => [%{"id" => machine}]} = json_response(call(:get, "/machines", read), 200)

    assert %{"name" => "nas", "services" => [%{"slug" => "nightly-backup"}]} =
             json_response(call(:get, "/machines/#{machine}", read), 200)

    assert %{"items" => [%{"slug" => "nightly-backup", "on" => [%{"machine" => "nas"}]}]} =
             json_response(call(:get, "/versions", read), 200)

    assert job
  end

  test "found things are accepted or dismissed, tasks are not", %{read: read, all: all} do
    {:ok, m} = Dokkit.Repo.insert(%Dokkit.Machine{name: "box"})

    Dokkit.Found.propose(m.id, %{
      "os" => "windows",
      "found" => %{
        "services" => [%{"name" => "Spooler", "state" => "running"}],
        "ports" => [%{"port" => 8080, "program" => "node"}]
      }
    })

    assert %{"items" => [a, b]} = json_response(call(:get, "/proposals", read), 200)
    assert json_response(call(:post, "/proposals/#{a["id"]}/accept", read), 403)
    assert json_response(call(:post, "/proposals/#{a["id"]}/accept", all), 200)
    assert json_response(call(:post, "/proposals/#{b["id"]}/dismiss", all), 200)
    assert json_response(call(:post, "/proposals/#{b["id"]}/dismiss", all), 404)
    assert %{"items" => []} = json_response(call(:get, "/proposals", read), 200)
    assert %{"services" => [_]} = json_response(call(:get, "/machines/#{m.id}", read), 200)
  end

  test "a service is unwatched and watched again, its checks edited, a version held, restart allowed",
       %{read: read, all: all, ops: ops} do
    %{"needs_you" => [%{"service" => id}]} = json_response(call(:get, "/inbox", read), 200)
    assert json_response(call(:post, "/services/#{id}/unwatch", read), 403)

    assert %{"state" => "unwatched"} =
             json_response(call(:post, "/services/#{id}/unwatch", all), 200)

    assert %{"needs_you" => [], "snoozed" => []} = json_response(call(:get, "/inbox", read), 200)

    # What it reports while nobody is watching opens nothing.
    check = Dokkit.Repo.get_by!(Dokkit.Check, service_id: id)
    for _ <- 1..4, do: Dokkit.Issues.record(check, :down)
    assert %{"needs_you" => []} = json_response(call(:get, "/inbox", read), 200)

    assert %{"state" => "unknown"} = json_response(call(:post, "/services/#{id}/watch", all), 200)

    assert %{"error" => %{"code" => "bad_checks"}} =
             json_response(
               call(:put, "/services/#{id}/checks", ops, %{checks: [%{name: "x", type: "job"}]}),
               422
             )

    web = %{
      name: "web",
      type: "http",
      config: %{url: "http://localhost:8080/healthz"},
      fail_after: 2
    }

    assert %{"checks" => checks} =
             json_response(call(:put, "/services/#{id}/checks", ops, %{checks: [web]}), 200)

    assert %{"type" => "http", "config" => %{"url" => "http://localhost:8080/healthz"}} =
             Enum.find(checks, &(&1["name"] == "web"))

    assert %{"checks" => [_job]} =
             json_response(call(:put, "/services/#{id}/checks", ops, %{checks: []}), 200)

    assert %{"held" => "1.4.2"} =
             json_response(call(:put, "/services/#{id}/hold", all, %{version: "1.4.2"}), 200)

    assert %{"held" => nil} = json_response(call(:put, "/services/#{id}/hold", all, %{}), 200)

    assert json_response(call(:put, "/services/#{id}/restart", all, %{allow: true}), 403)

    assert %{"restart" => true} =
             json_response(call(:put, "/services/#{id}/restart", ops, %{allow: true}), 200)

    assert json_response(call(:put, "/services/nope/restart", ops, %{allow: true}), 404)
  end

  test "an admin token manages keys and people, and nothing less does", %{job: job, all: all} do
    {admin, _} = Keys.mint(:user, %{scopes: ["admin"], label: "ops"})
    assert json_response(call(:get, "/keys", all), 403)
    assert json_response(call(:get, "/inbox", admin), 403)

    assert %{"key" => "dku_" <> _ = token, "id" => id} =
             json_response(
               call(:post, "/keys", admin, %{kind: "user", label: "ci", scopes: ["read", "fly"]}),
               200
             )

    assert json_response(call(:get, "/inbox", token), 200)
    assert json_response(call(:post, "/keys", admin, %{kind: "user", scopes: ["read"]}), 422)

    assert %{"key" => "dke_" <> _} =
             json_response(call(:post, "/keys", admin, %{kind: "enrol"}), 200)

    service = Dokkit.Repo.get_by!(Dokkit.Service, slug: "nightly-backup")

    assert %{"key" => "dka_" <> _} =
             json_response(call(:post, "/keys", admin, %{kind: "app", service: service.id}), 200)

    assert json_response(call(:post, "/keys", admin, %{kind: "app", service: "nope"}), 404)

    assert %{"items" => keys} = json_response(call(:get, "/keys", admin), 200)

    assert %{"label" => "ci", "scopes" => ["read"], "hint" => "dku_" <> _} =
             Enum.find(keys, &(&1["id"] == id))

    refute inspect(keys) =~ token
    assert json_response(call(:delete, "/keys/#{id}", admin), 200)
    assert json_response(call(:get, "/inbox", token), 401)

    assert %{"error" => %{"code" => "bad_person"}} =
             json_response(
               call(:post, "/users", admin, %{name: "ana", role: "member", password: "short"}),
               422
             )

    assert %{"id" => ana, "role" => "owner"} =
             json_response(
               call(:post, "/users", admin, %{
                 name: "ana",
                 role: "owner",
                 password: "a long enough password"
               }),
               200
             )

    assert %{"items" => [%{"name" => "ana"}]} = json_response(call(:get, "/users", admin), 200)

    assert %{"error" => %{"message" => "Someone has to be an owner."}} =
             json_response(call(:delete, "/users/#{ana}", admin), 422)

    assert job
  end
end
