defmodule DokkitWeb.ApiDepthTest do
  use DokkitWeb.ConnCase, async: false
  alias Dokkit.{Check, Estate, Issues, JobRun, Keys, Machine, Repo, Service}

  setup do
    {all, _} = Keys.mint(:user, %{scopes: ["read", "read-logs", "act", "admin"]})
    %{all: all}
  end

  defp call(method, path, token, body \\ %{}) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> dispatch(@endpoint, method, "/api/v1" <> path, body)
  end

  defp fail_job(name) do
    {:ok, job} = Estate.add_job(%{"name" => name, "machine" => "nas"})
    post(build_conn(), "/api/v1/in/#{job.key}/job/#{job.service.slug}/fail")
    job
  end

  defp walk(token, path, limit) do
    Stream.unfold(:first, fn
      nil ->
        nil

      cursor ->
        sep = if String.contains?(path, "?"), do: "&", else: "?"
        suffix = if cursor == :first, do: "", else: "&cursor=#{cursor}"
        body = json_response(call(:get, "#{path}#{sep}limit=#{limit}#{suffix}", token), 200)
        {body["items"], body["next"]}
    end)
    |> Enum.to_list()
  end

  test "issues page by cursor, with no gaps or repeats, and closed ones come by state", %{
    all: all
  } do
    jobs = for n <- 1..5, do: fail_job("Job #{n}")

    pages = walk(all, "/issues", 2)
    assert Enum.map(pages, &length/1) == [2, 2, 1]
    ids = pages |> List.flatten() |> Enum.map(& &1["id"])
    assert length(Enum.uniq(ids)) == 5

    first = json_response(call(:get, "/issues?limit=2", all), 200)
    fail_job("Job 6")
    second = json_response(call(:get, "/issues?limit=2&cursor=#{first["next"]}", all), 200)

    assert Enum.all?(
             second["items"],
             &(&1["id"] not in Enum.map(first["items"], fn i -> i["id"] end))
           )

    [job | _] = jobs
    post(build_conn(), "/api/v1/in/#{job.key}/job/#{job.service.slug}/ok")
    assert json_response(call(:get, "/issues?state=closed", all), 200)["items"] |> length() == 1
    assert json_response(call(:get, "/issues?state=all", all), 200)["items"] |> length() == 6
    assert json_response(call(:get, "/issues?q=job%203", all), 200)["items"] |> length() == 1
    assert code(call(:get, "/issues?cursor=nonsense", all)) == "bad_cursor"
    assert code(call(:get, "/issues?state=what", all)) == "bad_state"
    assert code(call(:get, "/issues?from=yesterday", all)) == "bad_time"
  end

  defp code(conn), do: json_response(conn, 422)["error"]["code"]

  test "an issue carries its history", %{all: all} do
    job = fail_job("Nightly")
    [issue] = Issues.open_list()
    post(build_conn(), "/api/v1/in/#{job.key}/job/#{job.service.slug}/fail")
    call(:post, "/issues/#{issue.id}/notes", all, %{text: "looking"})
    call(:post, "/issues/#{issue.id}/acknowledge", all)
    body = json_response(call(:get, "/issues/#{issue.id}", all), 200)
    assert Enum.map(body["history"], & &1["event"]) |> Enum.sort() == ~w(acknowledged note opened)
  end

  test "lists page and filter: machines, services, jobs, deploys, rules, users", %{all: all} do
    for n <- 1..3, do: Repo.insert!(%Machine{name: "box-#{n}"})
    assert [[_, _], [_]] = walk(all, "/machines?q=box", 2)
    assert [[%{"name" => "box-2"}]] = walk(all, "/machines?machine=box-2", 2)
    fail_job("Sync")
    assert [[%{"name" => "Sync"}]] = walk(all, "/jobs?q=sync", 5)
    assert [[]] = walk(all, "/jobs?environment=dev", 5)
    assert [[_ | _]] = walk(all, "/services?machine=nas", 5)
    assert json_response(call(:get, "/users", all), 200)["next"] == nil
    assert code(call(:get, "/rules?cursor=!!", all)) == "bad_cursor"
  end

  test "a service has its version on each machine, deploys and facts", %{all: all} do
    for host <- ~w(a-host b-host) do
      m = Repo.insert!(%Machine{name: host})

      Repo.insert!(%Service{
        machine_id: m.id,
        slug: "portal",
        name: "Portal",
        version: "1.#{String.length(host)}.0",
        declared: %{"service" => %{"id" => "portal", "owner" => "ops"}}
      })
    end

    [s | _] = Repo.all(Service)
    Dokkit.Deploys.record(s, "9.9.9")
    body = json_response(call(:get, "/services/#{s.id}", all), 200)
    assert length(body["versions"]) == 2
    assert [%{"version" => "9.9.9"}] = body["deploys"]
    assert %{"owner" => "ops"} = body["facts"]
  end

  test "an error group lists its reports by cursor", %{all: all} do
    m = Repo.insert!(%Machine{name: "vault"})
    s = Repo.insert!(%Service{machine_id: m.id, slug: "portal", name: "Portal"})
    {app, _} = Keys.mint(:app, %{service_id: s.id})
    as = put_req_header(build_conn(), "authorization", "Bearer " <> app)
    for _ <- 1..5, do: post(as, "/api/v1/errors", %{type: "TimeoutError"})
    [group] = json_response(call(:get, "/errors", all), 200)["items"]
    first = json_response(call(:get, "/errors/#{group["id"]}?limit=2", all), 200)
    assert length(first["reports"]["items"]) == 2

    rest =
      json_response(
        call(:get, "/errors/#{group["id"]}?limit=9&cursor=#{first["reports"]["next"]}", all),
        200
      )

    assert length(rest["reports"]["items"]) == 3 and rest["reports"]["next"] == nil
  end

  test "proposals are accepted and dismissed together", %{all: all} do
    {:ok, m} = Repo.insert(%Machine{name: "scan-box"})

    Dokkit.Found.propose(m.id, %{
      "os" => "windows",
      "found" => %{
        "services" => [%{"name" => "SpoolerA", "state" => "running"}],
        "ports" => [
          %{"port" => 8081, "program" => "node"},
          %{"port" => 8082, "program" => "node"}
        ]
      }
    })

    [a, b, c] = json_response(call(:get, "/proposals", all), 200)["items"]

    assert %{"done" => [_, _]} =
             json_response(
               call(:post, "/proposals/accept", all, %{ids: [a["id"], b["id"], "nope"]}),
               200
             )

    assert json_response(call(:post, "/proposals/dismiss", all, %{all: true}), 200)["done"] == [
             c["id"]
           ]

    assert call(:post, "/proposals/accept", all, %{ids: [a["id"]]}).status == 404
    assert json_response(call(:post, "/proposals/accept", all, %{all: true}), 200)["done"] == []
  end

  test "a running job shows its done and total", %{all: all} do
    {:ok, job} = Estate.add_job(%{"name" => "Import", "machine" => "nas"})
    check = Repo.get_by!(Check, service_id: job.service.id)

    Repo.insert!(%JobRun{
      check_id: check.id,
      run: "r1",
      result: :running,
      started_at: DateTime.utc_now(),
      done: 4000,
      total: 9000
    })

    assert [%{"done" => 4000, "total" => 9000, "result" => "running"}] =
             json_response(call(:get, "/jobs/#{job.service.id}/runs", all), 200)["items"]

    assert [%{"last_run" => %{"done" => 4000}}] =
             json_response(call(:get, "/jobs", all), 200)["items"]

    assert [%{"result" => "running"}] =
             json_response(call(:get, "/jobs/#{job.service.id}/runs?result=running", all), 200)[
               "items"
             ]

    assert [] =
             json_response(call(:get, "/jobs/#{job.service.id}/runs?result=ok", all), 200)[
               "items"
             ]
  end

  test "a dependency is added under Outside, or on the machine that checks it", %{all: all} do
    body = json_response(call(:post, "/dependencies", all, %{name: "Payment gateway"}), 200)
    assert %{"kind" => "dependency", "machine" => "Outside", "checks" => []} = body

    Repo.insert!(%Machine{name: "web-01", kind: :enrolled})

    body =
      json_response(
        call(:post, "/dependencies", all, %{
          name: "Mail relay",
          machine: "web-01",
          check: %{type: "tcp", address: "smtp.example.com:587"}
        }),
        200
      )

    assert %{
             "machine" => "web-01",
             "checks" => [%{"type" => "tcp", "config" => %{"port" => 587}}]
           } = body

    assert [%{type: :tcp}] =
             Dokkit.Found.checks(Repo.get_by!(Machine, name: "web-01").id)
             |> Enum.map(&Map.take(&1, [:type]))

    bad = fn params -> call(:post, "/dependencies", all, params) end
    assert code(bad.(%{})) == "bad_dependency"

    assert code(bad.(%{name: "X", check: %{type: "http", url: "https://x.example"}})) ==
             "bad_dependency"

    assert code(bad.(%{name: "X", machine: "web-01", check: %{type: "http", url: "ftp://x"}})) ==
             "bad_dependency"

    assert code(bad.(%{name: "X", machine: "nowhere"})) == "bad_dependency"
    assert code(bad.(%{name: "Mail relay", machine: "web-01"})) == "bad_dependency"

    {read, _} = Keys.mint(:user, %{scopes: ["read"]})
    assert call(:post, "/dependencies", read, %{name: "Z"}).status == 403
  end
end
