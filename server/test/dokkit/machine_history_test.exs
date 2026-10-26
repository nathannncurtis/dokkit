defmodule Dokkit.MachineHistoryTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Dokkit.{Keys, Machine, Numbers, Repo}

  defp token(scopes), do: elem(Keys.mint(:user, %{scopes: scopes, label: "x"}), 0)

  defp get_as(token, path),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get(path)

  defp mcp(token, args) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/mcp", %{
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: %{name: "series", arguments: args}
    })
    |> json_response(200)
    |> get_in(["result"])
  end

  defp machine(name) do
    machine = Repo.insert!(%Machine{name: name, kind: :enrolled})
    now = DateTime.utc_now()
    Numbers.record(machine.id, nil, "disk.used_percent.C", 71.0, DateTime.add(now, -3 * 3600))
    Numbers.record(machine.id, nil, "disk.used_percent.C", 73.0, DateTime.add(now, -60))
    Numbers.record(machine.id, nil, "memory.used_percent", 40.0, DateTime.add(now, -60))
    machine
  end

  test "a machine's own numbers are listed and charted like a service's" do
    m = machine("attic")
    t = token(~w(read))

    assert %{"metrics" => ["disk.used_percent.C", "memory.used_percent"]} =
             json_response(get_as(t, "/api/v1/machines/#{m.id}/series"), 200)

    path = "/api/v1/machines/#{m.id}/series?metric=disk.used_percent.C&points=4"

    assert %{"metric" => "disk.used_percent.C", "points" => points} =
             json_response(get_as(t, path), 200)

    assert [nil, nil, nil, 72.0] = Enum.map(points, & &1["value"])

    assert %{"metrics" => latest, "thresholds" => %{"disk_used_percent" => _}} =
             json_response(get_as(t, "/api/v1/machines/#{m.id}"), 200)

    assert [%{"name" => "disk.used_percent.C", "value" => 73.0, "at" => _}, _] = latest
  end

  test "a machine with no numbers, an unknown metric, an unknown machine and a bad time" do
    empty = Repo.insert!(%Machine{name: "cellar", kind: :enrolled})
    t = token(~w(read))

    assert %{"metrics" => []} =
             json_response(get_as(t, "/api/v1/machines/#{empty.id}/series"), 200)

    assert %{"metrics" => []} =
             json_response(get_as(t, "/api/v1/machines/#{empty.id}"), 200)

    path = "/api/v1/machines/#{empty.id}/series?metric=nope&points=3"
    assert %{"points" => [%{"value" => nil}, _, _]} = json_response(get_as(t, path), 200)

    assert json_response(get_as(t, "/api/v1/machines/#{Ecto.UUID.generate()}/series"), 404)
    assert json_response(get_as(t, "/api/v1/machines/#{empty.id}/series?from=soon"), 404)
  end

  test "reading a machine's series needs the read scope" do
    m = machine("loft")
    assert get_as(token(~w(act)), "/api/v1/machines/#{m.id}/series").status == 403
  end

  test "the series tool takes a machine instead of a service" do
    m = machine("shed")
    t = token(~w(read))
    refute mcp(t, %{machine: m.id})["isError"]

    assert mcp(t, %{machine: m.id})["content"] |> Enum.map_join(& &1["text"]) =~
             "disk.used_percent.C"

    assert mcp(t, %{machine: Ecto.UUID.generate()})["isError"]
    assert mcp(t, %{})["isError"]
  end

  test "the machine page draws a chart for each number, the disk first", %{conn: conn} do
    m = machine("porch")
    conn = signed_in(conn)
    {:ok, view, html} = live(conn, "/machines/#{m.id}")
    assert html =~ ~s(id="history-disk.used_percent.C")
    assert html =~ ~s(id="history-memory.used_percent")
    assert html =~ "Disk C in use"
    assert html =~ "<path"
    assert :binary.match(html, "history-disk") < :binary.match(html, "history-memory")

    html = view |> form("#range-form", %{range: "30"}) |> render_change()
    assert html =~ "history-memory.used_percent"
  end

  test "the machine page opens on Overview and each tab shows only its own panel", %{conn: conn} do
    m = machine("porch")
    {:ok, view, _} = live(signed_in(conn), "/machines/#{m.id}")
    assert has_element?(view, "#panel-overview:not([hidden])")
    assert has_element?(view, "#panel-alerts[hidden]")

    view |> element("#tab-alerts") |> render_click()
    assert_patch(view, "/machines/#{m.id}?tab=alerts")
    assert has_element?(view, "#panel-alerts:not([hidden]) #silent-form")
    assert has_element?(view, "#panel-overview[hidden]")

    {:ok, view, _} = live(signed_in(build_conn()), "/machines/#{m.id}?tab=downtime")
    assert has_element?(view, "#tab-downtime[aria-selected=true]")
  end

  test "a machine with no readings says so", %{conn: conn} do
    m = Repo.insert!(%Machine{name: "pantry", kind: :enrolled})

    {:ok, _, html} = live(signed_in(conn), "/machines/#{m.id}")
    assert html =~ "No readings yet"
  end
end
