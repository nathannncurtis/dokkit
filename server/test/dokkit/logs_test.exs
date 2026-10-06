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
        %{type: "log", level: "info"}
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
end
