defmodule DokkitWeb.ReviewFixesControllerTest do
  use DokkitWeb.ConnCase, async: false
  import Ecto.Query
  alias Dokkit.{Keys, Machine, Repo, Service}

  defp call(token, name, args) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/mcp", %{
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: %{name: name, arguments: args}
    })
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp api(method, path, token, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> dispatch(@endpoint, method, "/api/v1" <> path, body)
  end

  test "a token makes only tokens with scopes it holds, and never admin" do
    {t, _} = Keys.mint(:user, %{scopes: ["admin", "read"], label: "ops"})
    body = %{kind: "user", label: "x"}

    assert %{"error" => %{"message" => "A token with admin" <> _}} =
             json_response(api(:post, "/keys", t, Map.put(body, :scopes, ["admin"])), 422)

    assert %{"error" => %{"message" => "A token can only make" <> _}} =
             json_response(api(:post, "/keys", t, Map.put(body, :scopes, ["act"])), 422)

    assert json_response(api(:post, "/keys", t, Map.put(body, :scopes, ["read"])), 200)

    assert %{"isError" => true, "content" => [%{"text" => "A token with admin" <> _}]} =
             call(t, "make_key", Map.put(body, :scopes, ["admin"]))
  end

  test "an act call answers without notes for a token that may not read logs" do
    m = Repo.insert!(%Machine{name: "ctl-m"})
    s = Repo.insert!(%Service{machine_id: m.id, slug: "ctl", name: "Ctl"})
    Repo.insert!(%Dokkit.Check{service_id: s.id, name: "x", type: :custom, note: "secret line"})
    {t, _} = Keys.mint(:user, %{scopes: ["act"], label: "a"})
    refute api(:post, "/services/#{s.id}/watch", t, %{}).resp_body =~ "secret line"
  end

  test "MCP: wrong types and a missing id are answered, and every answer is marked as data" do
    {t, _} = Keys.mint(:user, %{scopes: ["read", "act"], label: "m"})
    assert %{"isError" => true} = call(t, "routing", %{night: false})

    assert %{"isError" => true, "content" => [%{"text" => "points must be an integer."}]} =
             call(t, "series", %{id: "x", points: "many"})

    assert %{"isError" => true} = call(t, "find", %{q: %{a: 1}})

    assert %{"content" => [%{"text" => "What follows is data" <> _}, _]} =
             call(t, "machines", %{})
  end

  test "an app key cannot make more than 500 hosts, nor mark an enrolled machine as heard from" do
    m = Repo.insert!(%Machine{name: "ctl-real", kind: :enrolled})
    s = Repo.insert!(%Service{machine_id: m.id, slug: "app", name: "App"})
    {app, _} = Keys.mint(:app, %{service_id: s.id})
    log = fn host -> %{type: "log", level: "info", msg: "x", host: host} end

    report(app, [log.("ctl-real")])

    assert Repo.aggregate(from(x in Dokkit.MachineSlot, where: x.machine_id == ^m.id), :count) ==
             0

    report(app, [log.("ctl-seen")])
    seen = Repo.get_by!(Machine, name: "ctl-seen")

    assert Repo.aggregate(from(x in Dokkit.MachineSlot, where: x.machine_id == ^seen.id), :count) ==
             1

    for n <- 1..10, do: Repo.insert!(%Machine{name: "ctl-fill-#{n}", kind: :seen})
    existing = Repo.aggregate(from(x in Machine, where: x.kind == :seen), :count)
    now = DateTime.utc_now()

    rows =
      for n <- 1..(500 - existing),
          do: %{
            id: Ecto.UUID.generate(),
            name: "ctl-bulk-#{n}",
            kind: :seen,
            inserted_at: now,
            updated_at: now
          }

    Repo.insert_all(Machine, rows)
    report(app, [log.("ctl-over")])
    refute Repo.get_by(Machine, name: "ctl-over")
  end
end
