defmodule DokkitWeb.DeleteLogsTest do
  use DokkitWeb.ConnCase, async: false
  import Ecto.Query
  alias Dokkit.{Estate, Keys, Log, Logs, Machine, Repo}

  setup do
    {:ok, a} = Estate.add_job(%{"name" => "Catch-all", "machine" => "nas"})
    {:ok, b} = Estate.add_job(%{"name" => "Records Finder", "machine" => "desk"})
    {admin, _} = Keys.mint(:user, %{scopes: ["admin"]})
    {act, _} = Keys.mint(:user, %{scopes: ["read", "act"]})
    %{svc: a.service, other: b.service, admin: admin, act: act}
  end

  defp purge(token, id, body, query \\ "") do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/api/v1/services/#{id}/logs/delete" <> query, body)
  end

  defp lines(service, entries) do
    machine = Repo.insert!(%Machine{name: "src-#{System.unique_integer([:positive])}"})

    rows =
      for {at, app, level, msg} <- entries do
        Logs.ensure_partition(at)

        %{
          at: at,
          received_at: at,
          level: level,
          msg: msg,
          fields: %{"app_name" => app},
          cut: false,
          machine_id: machine.id,
          service_id: service.id
        }
      end

    Repo.insert_all(Log, rows)
  end

  defp count(service),
    do: Repo.aggregate(from(l in Log, where: l.service_id == ^service.id), :count)

  @sep ~U[2026-09-15 10:00:00.000000Z]
  @oct ~U[2026-10-05 10:00:00.000000Z]

  defp mixed(service) do
    lines(service, [
      {@sep, "A", "info", "Timed out after 50% of 10_s"},
      {@oct, "B", "debug", "all fine"},
      {@oct, "B", "error", "TIMED OUT"},
      {@sep, "A", "info", "other"}
    ])
  end

  test "a dry run counts and changes nothing", %{svc: svc, admin: admin} do
    mixed(svc)
    body = %{field: "app_name", values: ["A"]}
    assert %{"would_delete" => 2} = json_response(purge(admin, svc.id, body, "?dry=true"), 200)
    assert count(svc) == 4
  end

  test "deletes by message text, case-insensitive and escaped", %{svc: svc, admin: admin} do
    mixed(svc)
    assert %{"deleted" => 1} = json_response(purge(admin, svc.id, %{q: "50% of 10_s"}), 200)
    assert count(svc) == 3
    assert %{"deleted" => 1} = json_response(purge(admin, svc.id, %{q: "timed out"}), 200)
    assert count(svc) == 2
  end

  test "deletes by field values", %{svc: svc, admin: admin} do
    mixed(svc)
    body = %{field: "app_name", values: ["B"]}
    assert %{"deleted" => 2} = json_response(purge(admin, svc.id, body), 200)
    assert count(svc) == 2
  end

  test "deletes by level and time range", %{svc: svc, admin: admin} do
    mixed(svc)
    assert %{"deleted" => 2} = json_response(purge(admin, svc.id, %{level: "info"}), 200)

    body = %{level: "debug", from: "2026-10-01T00:00:00Z", until: "2026-11-01T00:00:00Z"}
    assert %{"deleted" => 1} = json_response(purge(admin, svc.id, body), 200)
    assert count(svc) == 1
  end

  test "a body with no filter is refused", %{svc: svc, admin: admin} do
    mixed(svc)
    code = fn body -> json_response(purge(admin, svc.id, body), 422)["error"]["code"] end
    assert code.(%{}) == "no_filter"
    assert code.(%{q: "  "}) == "no_filter"
    assert code.(%{level: "loud"}) == "bad_delete"
    assert code.(%{field: "app_name"}) == "bad_delete"
    assert code.(%{from: "yesterday"}) == "bad_time"
    assert count(svc) == 4
  end

  test "an unknown service is not found", %{admin: admin} do
    body = purge(admin, Ecto.UUID.generate(), %{q: "x"})
    assert json_response(body, 404)["error"]["code"] == "not_found"
  end

  test "other services are untouched", %{svc: svc, other: other, admin: admin} do
    mixed(svc)
    mixed(other)
    assert %{"deleted" => 2} = json_response(purge(admin, svc.id, %{level: "info"}), 200)
    assert count(svc) == 2
    assert count(other) == 4
  end

  test "lines in two monthly partitions go together", %{svc: svc, admin: admin} do
    lines(svc, [{@sep, "A", "info", "x"}, {@oct, "A", "info", "x"}])
    assert %{"deleted" => 2} = json_response(purge(admin, svc.id, %{q: "x"}), 200)
    assert count(svc) == 0
  end

  test "the module deletes in batches", %{svc: svc} do
    lines(svc, for(i <- 1..5, do: {DateTime.add(@sep, i), "A", "info", "x"}))
    assert Logs.delete(svc.id, q: "x") == 5
  end

  test "needs the admin scope", %{svc: svc, act: act} do
    assert json_response(purge(act, svc.id, %{q: "x"}), 403)["error"]["code"] == "no_scope"
  end
end
