defmodule Dokkit.DayTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias Dokkit.{Alert, Issue, Keys, Machine, MachineSlot, Read, Repo, Service, Slots}

  # The window is Jan 9 12:30 to Jan 10 12:30, so cell 43 is Jan 10 10:00.
  @now ~U[2026-01-10 12:10:00Z]
  @from ~U[2026-01-09 12:30:00Z]

  defp at(h, m), do: %{@now | hour: h, minute: m}
  defp machine(name, kind \\ :enrolled), do: Repo.insert!(%Machine{name: name, kind: kind})

  defp service(m, env \\ "production"),
    do:
      Repo.insert!(%Service{
        machine_id: m.id,
        slug: "s#{System.unique_integer([:positive])}",
        name: "S",
        environment: env
      })

  defp issue(m, attrs) do
    base = %{machine_id: m.id, kind: "check", state: :down, title: "T", since: at(10, 5)}
    attrs = Map.merge(base, Map.new(attrs))
    usec = &(&1 && %{&1 | microsecond: {0, 6}})
    attrs = %{attrs | since: usec.(attrs.since)} |> Map.update(:closed_at, nil, usec)
    Repo.insert!(struct!(Issue, attrs))
  end

  defp cells(name), do: Enum.find(Read.day(@now).machines, &(&1.name == name)).cells

  test "a window is 48 half hours ending with the one that holds the time" do
    machine("w-a")
    day = Read.day(@now)
    assert day.from == @from
    assert day.to == ~U[2026-01-10 12:30:00Z]
    assert length(cells("w-a")) == 48
  end

  test "an issue down for two half hours colours two cells, and down wins over degraded" do
    m = machine("d-a")
    s = service(m)
    issue(m, service_id: s.id, since: at(10, 5), closed_at: at(10, 50))
    issue(m, service_id: s.id, state: :degraded, since: at(10, 20), closed_at: at(10, 40))
    issue(m, service_id: s.id, state: :degraded, since: at(11, 40))
    c = cells("d-a")
    assert Enum.slice(c, 42, 4) == ["none", "down", "down", "none"]
    assert Enum.slice(c, 46, 2) == ["degraded", "degraded"]
  end

  test "soon issues and issues of other environments colour nothing" do
    m = machine("d-b")
    issue(m, service_id: service(m).id, soon: true, state: :degraded)
    issue(m, service_id: service(m, "dev").id)
    assert Enum.uniq(cells("d-b")) == ["none"]
    assert Read.day(@now).events == []
  end

  test "a machine heard from is quiet, and a seen machine shows no signal elsewhere" do
    pc = machine("d-pc", :seen)

    for n <- 10..12,
        do: Repo.insert!(%MachineSlot{machine_id: pc.id, slot: DateTime.add(@from, n * 1800)})

    c = cells("d-pc")
    assert Enum.slice(c, 9, 5) == ["none", "quiet", "quiet", "quiet", "none"]
    assert Enum.count(c, &(&1 == "none")) == 45
  end

  test "a seen machine never heard from in the window is not listed" do
    machine("d-gone", :seen)
    refute Enum.any?(Read.day(@now).machines, &(&1.name == "d-gone"))
  end

  test "events are the issues that opened, oldest first, with what was sent" do
    m = machine("e-a")
    s = service(m)
    late = issue(m, service_id: s.id, title: "Late", since: at(11, 0))
    issue(m, service_id: s.id, title: "Early", since: at(9, 0), closed_at: at(9, 30))
    issue(m, service_id: s.id, title: "Before", since: ~U[2026-01-08 09:00:00Z])
    Repo.insert!(%Alert{issue_id: late.id, channel: "page", status: :sent})

    assert [
             %{title: "Early", sent: nil, closed_at: closed, machine: "e-a"},
             %{title: "Late", sent: "Paged", closed_at: nil, state: :down}
           ] = Read.day(@now).events

    assert DateTime.compare(closed, at(9, 30)) == :eq
  end

  test "an issue that began before the window colours it from the first cell" do
    m = machine("e-b")
    issue(m, since: ~U[2026-01-08 09:00:00Z], closed_at: at(0, 40))
    c = cells("e-b")
    assert Enum.slice(c, 0, 25) |> Enum.uniq() == ["down"]
    assert Enum.at(c, 25) == "none"
  end

  test "a machine is written once for each half hour, and a new half hour writes again" do
    m = machine("s-a")
    count = fn -> Repo.aggregate(from(s in MachineSlot, where: s.machine_id == ^m.id), :count) end
    Slots.touch(m.id, at(10, 1))
    assert count.() == 1
    Repo.delete_all(from s in MachineSlot, where: s.machine_id == ^m.id)
    Slots.touch(m.id, at(10, 29))
    assert count.() == 0
    Slots.touch(m.id, at(10, 31))
    assert count.() == 1
  end

  test "a report from a machine, and an app naming a host, write the slot" do
    m = machine("s-b")
    {key, _} = Keys.mint(:machine, %{machine_id: m.id})
    report(key, [%{type: "log", level: "info", msg: "hi"}])
    assert Repo.exists?(from s in MachineSlot, where: s.machine_id == ^m.id)

    host = machine("s-host", :seen)
    Slots.touch_named([host.name])
    assert Repo.exists?(from s in MachineSlot, where: s.machine_id == ^host.id)
  end

  test "slots older than 30 days are pruned" do
    m = machine("s-c")
    Repo.insert!(%MachineSlot{machine_id: m.id, slot: ~U[2025-12-01 10:00:00Z]})
    Repo.insert!(%MachineSlot{machine_id: m.id, slot: ~U[2026-01-09 10:00:00Z]})
    Slots.prune(@now)

    assert [~U[2026-01-09 10:00:00Z]] =
             Repo.all(from s in MachineSlot, where: s.machine_id == ^m.id, select: s.slot)
  end

  defp token do
    {key, _} = Keys.mint(:user, %{scopes: ["read"]})
    key
  end

  test "the API gives the day, takes to, and refuses a bad one" do
    m = machine("api-a")
    issue(m, since: at(10, 5), closed_at: at(10, 50))
    auth = &put_req_header(build_conn(), "authorization", "Bearer " <> &1)

    day = json_response(get(auth.(token()), "/api/v1/day?to=2026-01-10T12:10:00Z"), 200)
    assert day["from"] == "2026-01-09T12:30:00Z"
    assert %{"cells" => cells} = Enum.find(day["machines"], &(&1["name"] == "api-a"))
    assert Enum.slice(cells, 43, 2) == ["down", "down"]
    assert [%{"title" => "T", "machine" => "api-a"}] = day["events"]

    assert %{"error" => %{"code" => "bad_time"}} =
             json_response(get(auth.(token()), "/api/v1/day?to=soon"), 422)

    assert json_response(get(build_conn(), "/api/v1/day"), 401)
    {no, _} = Keys.mint(:user, %{scopes: ["act"]})
    assert json_response(get(auth.(no), "/api/v1/day"), 403)
  end

  test "the MCP tool gives the day" do
    machine("mcp-a")

    result =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token())
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "day", arguments: %{to: "2026-01-10T12:10:00Z"}}
      })
      |> json_response(200)

    [%{"text" => "What follows is data" <> _}, %{"text" => text}] = result["result"]["content"]
    assert %{"machines" => [_ | _], "events" => []} = Jason.decode!(text)
  end

  test "the first screen draws the last day with a title on every cell", %{conn: conn} do
    m = machine("ui-vault")
    s = service(m)
    issue(m, service_id: s.id, since: DateTime.add(DateTime.utc_now(), -300))
    {:ok, _, html} = live(signed_in(conn), "/")
    assert html =~ "The last day"
    assert html =~ ~r/ui-vault at \d\d:\d\d: something was down/
    assert html =~ ~r/ui-vault at \d\d:\d\d: no signal/
    assert html =~ ~s(href="/all#m-#{m.id}")
  end
end
