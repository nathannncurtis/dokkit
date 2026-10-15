defmodule DokkitWeb.MoveLogsTest do
  use DokkitWeb.ConnCase, async: false
  import Ecto.Query
  alias Dokkit.{Estate, Keys, Log, Logs, Machine, Repo}

  setup do
    {:ok, a} = Estate.add_job(%{"name" => "Catch-all", "machine" => "nas"})
    {:ok, b} = Estate.add_job(%{"name" => "Records Finder", "machine" => "desk"})
    {admin, _} = Keys.mint(:user, %{scopes: ["admin"]})
    {act, _} = Keys.mint(:user, %{scopes: ["read", "act"]})
    %{from: a.service, to: b.service, admin: admin, act: act}
  end

  defp move(token, id, body, query \\ "") do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/api/v1/services/#{id}/logs/move" <> query, body)
  end

  defp lines(service, entries) do
    machine = Repo.insert!(%Machine{name: "src-#{System.unique_integer([:positive])}"})

    rows =
      for {at, app} <- entries do
        Logs.ensure_partition(at)

        %{
          at: at,
          received_at: at,
          level: "info",
          msg: "line",
          fields: %{"app_name" => app},
          cut: false,
          machine_id: machine.id,
          service_id: service.id
        }
      end

    Repo.insert_all(Log, rows)
    machine
  end

  defp count(service),
    do: Repo.aggregate(from(l in Log, where: l.service_id == ^service.id), :count)

  @jan ~U[2026-09-15 10:00:00.000000Z]
  @feb ~U[2026-10-05 10:00:00.000000Z]

  test "a dry run counts and changes nothing", %{from: from, to: to, admin: admin} do
    lines(from, [{@jan, "Records Finder"}, {@jan, "Other"}])
    body = %{to: to.id, field: "app_name", values: ["Records Finder"]}
    assert %{"would_move" => 1} = json_response(move(admin, from.id, body, "?dry=true"), 200)
    assert count(from) == 2
    assert count(to) == 0
  end

  test "moves the lines whose field is one of the values, with the target's machine", ctx do
    %{from: from, to: to, admin: admin} = ctx

    lines(from, [{@jan, "Records Finder"}, {@feb, "Records Finder Setup Helper"}, {@jan, "Other"}])

    body = %{
      to: to.id,
      field: "app_name",
      values: ["Records Finder", "Records Finder Setup Helper"]
    }

    assert %{"moved" => 2} = json_response(move(admin, from.id, body), 200)
    assert count(from) == 1
    assert count(to) == 2
    machine = Repo.get!(Dokkit.Service, to.id).machine_id

    assert Repo.all(from l in Log, where: l.service_id == ^to.id, select: l.machine_id) == [
             machine,
             machine
           ]
  end

  test "without a field every line moves", %{from: from, to: to, admin: admin} do
    lines(from, [{@jan, "A"}, {@feb, "B"}])
    assert %{"moved" => 2} = json_response(move(admin, from.id, %{to: to.id}), 200)
    assert count(from) == 0
  end

  test "q moves the lines whose message contains the text", %{from: from, to: to, admin: admin} do
    lines(from, [{@jan, "A"}, {@jan, "A"}, {@feb, "A"}])
    [first | _] = Repo.all(from l in Log, where: l.service_id == ^from.id, select: l.id)

    Repo.update_all(from(l in Log, where: l.id == ^first),
      set: [msg: "[Records Finder | rlee] done"]
    )

    body = %{to: to.id, q: "[Records Finder |"}
    assert %{"moved" => 1} = json_response(move(admin, from.id, body), 200)
    assert count(from) == 2
    assert code(move(admin, from.id, %{to: to.id, q: 5}), 422) == "bad_move"
  end

  defp code(conn, status), do: json_response(conn, status)["error"]["code"]

  test "a time range limits the move", %{from: from, to: to, admin: admin} do
    lines(from, [{@jan, "A"}, {@feb, "A"}])
    body = %{to: to.id, from: "2026-10-01T00:00:00Z", until: "2026-11-01T00:00:00Z"}
    assert %{"moved" => 1} = json_response(move(admin, from.id, body), 200)
    assert count(from) == 1
  end

  test "the module moves by field values", %{from: from, to: to} do
    lines(from, for(i <- 1..5, do: {DateTime.add(@jan, i), "A"}))
    assert Logs.move(from.id, to.id, field: "app_name", values: ["A"]) == 5
    assert count(to) == 5
  end

  test "bad requests", %{from: from, to: to, admin: admin} do
    code = fn conn, status -> json_response(conn, status)["error"]["code"] end
    assert code.(move(admin, Ecto.UUID.generate(), %{to: to.id}), 404) == "not_found"
    assert code.(move(admin, from.id, %{to: Ecto.UUID.generate()}), 404) == "not_found"
    assert code.(move(admin, from.id, %{to: from.id}), 422) == "bad_move"
    assert code.(move(admin, from.id, %{}), 422) == "bad_move"
    bad = %{to: to.id, field: "a'b", values: ["x"]}
    assert code.(move(admin, from.id, bad), 422) == "bad_move"
    many = %{to: to.id, field: "app_name", values: for(i <- 1..201, do: "v#{i}")}
    assert code.(move(admin, from.id, many), 422) == "bad_move"
    assert code.(move(admin, from.id, %{to: to.id, field: "app_name"}), 422) == "bad_move"
    assert code.(move(admin, from.id, %{to: to.id, from: "yesterday"}), 422) == "bad_time"
  end

  test "needs the admin scope", %{from: from, to: to, act: act} do
    assert json_response(move(act, from.id, %{to: to.id}), 403)["error"]["code"] == "no_scope"
  end
end
