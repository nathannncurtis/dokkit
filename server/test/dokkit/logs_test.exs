defmodule Dokkit.LogsTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Dokkit.{Keys, Logs, Machine, Repo, Service}

  setup do
    machine = Repo.insert!(%Machine{name: "vault"})

    service =
      Repo.insert!(%Service{machine_id: machine.id, slug: "portal", name: "Upload portal"})

    {app, _} = Keys.mint(:app, %{service_id: service.id})
    {mkey, _} = Keys.mint(:machine, %{machine_id: machine.id})
    %{service: service, app: app, mkey: mkey}
  end

  test "a line far older than a year is stamped now, even when its own sender's time is old", %{
    app: app
  } do
    old = fn days ->
      DateTime.utc_now() |> DateTime.add(-days * 86_400) |> DateTime.to_iso8601()
    end

    assert %{"accepted" => 1} =
             report(app, [%{type: "log", at: old.(700), t: old.(720), msg: "ancient"}])
             |> json_response(200)

    assert [%{msg: "ancient", at: at}] = Logs.list(q: "ancient")
    assert DateTime.diff(DateTime.utc_now(), at) < 60
  end

  test "log lines come in as Dokkit lines or CLEF, and can be searched", %{
    conn: conn,
    service: service,
    app: app,
    mkey: mkey
  } do
    day = Date.to_iso8601(Date.add(Date.utc_today(), -2))

    answer =
      report(app, [
        %{
          type: "log",
          t: day <> "T21:14:03.120Z",
          level: "error",
          msg: "Upload failed 100%",
          fields: %{status: 500}
        },
        %{
          :type => "log",
          "@t" => day <> "T21:15:00Z",
          "@mt" => "User {User} signed in from {Ip}",
          "User" => "sam",
          "Ip" => "10.0.0.4",
          "@l" => "Warning",
          "@x" => "boom"
        },
        "not json"
      ])

    assert %{"accepted" => 2, "refused" => [%{"line" => 3, "code" => "bad_line"}]} =
             json_response(answer, 200)

    assert %{"accepted" => 1} =
             report(mkey, [%{type: "log", level: "nonsense", msg: String.duplicate("x", 70_000)}])
             |> json_response(200)

    [machine_line, clef, plain] = Logs.list()
    assert machine_line.cut and machine_line.level == "info" and machine_line.service_id == nil
    assert byte_size(machine_line.msg) == 65_536
    assert clef.msg == "User sam signed in from 10.0.0.4"
    assert clef.level == "warn"
    assert clef.fields == %{"User" => "sam", "Ip" => "10.0.0.4", "exception" => "boom"}
    assert plain.fields == %{"status" => 500}
    assert DateTime.to_iso8601(plain.at) == day <> "T21:14:03.120000Z"

    assert [%{msg: "Upload failed 100%"}] = Logs.list(q: "failed 100%")
    assert Logs.list(q: "100_") == []
    assert length(Logs.list(level: "warn")) == 2
    assert length(Logs.list(service: service.id)) == 2

    {:ok, view, html} = live(signed_in(conn), "/logs")
    assert html =~ "User sam signed in"
    assert html =~ "The machine"

    html = view |> form("#log-filter", %{q: "upload", level: "error"}) |> render_change()
    assert html =~ "Upload failed"
    refute html =~ "User sam signed in"

    {:ok, _, html} = live(signed_in(conn), "/s/#{service.id}")
    assert html =~ "Latest logs"
    assert html =~ "Upload failed 100%"

    {:ok, _, html} = live(signed_in(conn), "/logs?s=#{service.id}")
    assert html =~ "Clear the service filter"
  end

  test "the Logs page sorts by any column, filters by machine, service and time, and exports every match, newest first",
       %{conn: conn, service: service} do
    other = Repo.insert!(%Machine{name: "attic"})
    now = DateTime.utc_now()

    line = fn machine, service_id, level, msg, minutes ->
      %{
        at: DateTime.add(now, -minutes * 60),
        received_at: now,
        machine_id: machine,
        service_id: service_id,
        level: level,
        msg: msg,
        fields: %{},
        cut: false
      }
    end

    Logs.insert([
      line.(service.machine_id, service.id, "info", "alpha upload", 5),
      line.(service.machine_id, service.id, "error", "=bravo, \"quoted\"", 30),
      line.(other.id, nil, "warn", "charlie disk", 200)
    ])

    {:ok, view, html} = live(signed_in(conn), "/logs")
    assert html =~ ~r/aria-sort="descending"[^>]*>\s*<a[^>]*sort=at/
    assert order(html) == ["alpha upload", "=bravo, &quot;quoted&quot;", "charlie disk"]

    html = view |> element("th a", "Level") |> render_click()
    assert order(html) == ["alpha upload", "charlie disk", "=bravo, &quot;quoted&quot;"]
    assert html =~ ~s(aria-sort="ascending")

    html = view |> element("th a", "Level") |> render_click()
    assert order(html) == ["=bravo, &quot;quoted&quot;", "charlie disk", "alpha upload"]

    html = view |> form("#log-filter", %{m: other.id}) |> render_change()
    assert order(html) == ["charlie disk"]

    html = view |> form("#log-filter", %{m: "", since: "60"}) |> render_change()
    assert order(html) == ["=bravo, &quot;quoted&quot;", "alpha upload"]

    html =
      view |> form("#log-filter", %{since: "", s: service.id, level: "error"}) |> render_change()

    assert order(html) == ["=bravo, &quot;quoted&quot;"]
    assert html =~ ~s(href="/logs.csv?)

    csv = signed_in(conn) |> get("/logs.csv?sort=level&dir=asc") |> response(200)

    assert csv ==
             "﻿time,level,machine,service,message\r\n" <>
               "#{DateTime.to_iso8601(DateTime.add(now, -300))},info,vault,Upload portal,alpha upload\r\n" <>
               "#{DateTime.to_iso8601(DateTime.add(now, -1800))},error,vault,Upload portal,\"'=bravo, \"\"quoted\"\"\"\r\n" <>
               "#{DateTime.to_iso8601(DateTime.add(now, -12_000))},warn,attic,,charlie disk\r\n"

    csv = signed_in(conn) |> get("/logs.csv?m=#{other.id}") |> response(200)
    assert csv =~ "charlie disk" and not (csv =~ "alpha")

    assert build_conn() |> get("/logs.csv") |> redirected_to() =~ "/login"
  end

  test "a machine's own service chosen by a link stays chosen in the filter", %{
    conn: conn,
    service: service
  } do
    own =
      Repo.insert!(%Service{
        machine_id: service.machine_id,
        slug: "machine",
        name: "The machine itself"
      })

    {:ok, view, html} = live(signed_in(conn), "/logs?s=#{own.id}")

    assert html =~
             ~r/<option[^>]*selected[^>]*value="#{own.id}"|<option[^>]*value="#{own.id}"[^>]*selected/

    html = view |> form("#log-filter", %{q: "x", s: own.id}) |> render_change()
    assert html =~ own.id
  end

  defp order(html) do
    Regex.scan(~r/<td class="msg">([^<]*)/, html, capture: :all_but_first) |> List.flatten()
  end
end
