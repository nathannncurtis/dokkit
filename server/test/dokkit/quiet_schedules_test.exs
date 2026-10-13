defmodule Dokkit.QuietSchedulesTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Dokkit.{Alerts, Check, Issues, Keys, Machine, Quiet, QuietSchedules, QuietWindow, Repo}
  alias Dokkit.{QuietSchedule, Service}

  setup do
    Req.Test.stub(Alerts, fn conn -> Plug.Conn.send_resp(conn, 202, "{}") end)
    :ok
  end

  defp machine(name, seen_ago \\ 0) do
    Repo.insert!(%Machine{
      name: name,
      kind: :enrolled,
      last_seen_at: DateTime.add(DateTime.utc_now(), -seen_ago)
    })
  end

  defp token(scopes), do: elem(Keys.mint(:user, %{scopes: scopes, label: "ops"}), 0)

  defp as(token, verb, path, body \\ nil) do
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

    if body,
      do: dispatch(conn, @endpoint, verb, path, body),
      else: dispatch(conn, @endpoint, verb, path)
  end

  defp la, do: Alerts.save(%{"night_zone" => "America/Los_Angeles"})

  defp schedule!(m, params, now \\ ~U[2030-06-01 00:00:00.000000Z]),
    do: elem(QuietSchedules.add(m.id, params, "ana", now), 1)

  defp daily(m, time, length, reason \\ "nightly update"),
    do: schedule!(m, %{"repeat" => "daily", "time" => time, "for" => length, "reason" => reason})

  defp end_windows,
    do: Repo.update_all(QuietWindow, set: [ended_at: ~U[2030-01-01 00:00:00.000000Z]])

  test "a one-off starts at its time and is removed" do
    m = machine("attic")

    schedule!(m, %{
      "repeat" => "once",
      "at" => "2030-06-12T21:00:00Z",
      "for" => "2h",
      "reason" => "Windows updates"
    })

    Quiet.tick(~U[2030-06-12 20:59:00.000000Z])
    assert Quiet.active(~U[2030-06-12 20:59:00.000000Z]) == []
    assert [%QuietSchedule{}] = Repo.all(QuietSchedule)

    Quiet.tick(~U[2030-06-12 21:00:30.000000Z])

    assert [%QuietWindow{by: "schedule (ana)", hold: true, reason: "Windows updates"} = w] =
             Quiet.active(~U[2030-06-12 21:00:30.000000Z])

    assert DateTime.diff(w.until, ~U[2030-06-12 23:00:00.000000Z]) == 0
    assert Repo.all(QuietSchedule) == []
  end

  test "a server that was down at the start covers what is left, and an expired one-off only goes" do
    m = machine("attic")
    other = machine("cellar")
    params = %{"repeat" => "once", "at" => "2030-06-12T21:00:00Z", "for" => "2h"}
    schedule!(m, params)
    schedule!(other, params)

    Quiet.tick(~U[2030-06-12 22:00:00.000000Z])

    assert [%QuietWindow{} = w, %QuietWindow{} = v] =
             Quiet.active(~U[2030-06-12 22:00:00.000000Z])

    assert DateTime.diff(w.until, ~U[2030-06-12 23:00:00.000000Z]) == 0
    assert DateTime.diff(v.until, ~U[2030-06-12 23:00:00.000000Z]) == 0

    third = machine("loft")
    schedule!(third, params)
    Quiet.tick(~U[2030-06-12 23:30:00.000000Z])
    assert Repo.all(QuietSchedule) == []
    assert [_, _] = Repo.all(QuietWindow)
  end

  test "a daily schedule starts in the night time zone and at most once a day" do
    la()
    m = machine("attic")
    s = daily(m, "02:00", "30m")

    Quiet.tick(~U[2030-06-12 08:59:00.000000Z])
    assert Quiet.active(~U[2030-06-12 08:59:00.000000Z]) == []

    Quiet.tick(~U[2030-06-12 09:10:00.000000Z])
    assert [%QuietWindow{until: until}] = Quiet.active(~U[2030-06-12 09:10:00.000000Z])
    assert DateTime.diff(until, ~U[2030-06-12 09:30:00.000000Z]) == 0
    assert Repo.get!(QuietSchedule, s.id).last_started_on == ~D[2030-06-12]

    end_windows()
    Quiet.tick(~U[2030-06-12 09:20:00.000000Z])
    assert Quiet.active(~U[2030-06-12 09:20:00.000000Z]) == []

    Quiet.tick(~U[2030-06-13 09:05:00.000000Z])
    assert [%QuietWindow{}] = Quiet.active(~U[2030-06-13 09:05:00.000000Z])
    assert Repo.get!(QuietSchedule, s.id).last_started_on == ~D[2030-06-13]
  end

  test "a weekly schedule starts only on its days" do
    m = machine("attic")
    wednesday = Date.day_of_week(~D[2030-06-12])
    thursday = wednesday + 1

    schedule!(m, %{
      "repeat" => "weekly",
      "time" => "09:00",
      "days" => [thursday],
      "for" => "1h"
    })

    Quiet.tick(~U[2030-06-12 09:10:00.000000Z])
    assert Quiet.active(~U[2030-06-12 09:10:00.000000Z]) == []
    Quiet.tick(~U[2030-06-13 09:10:00.000000Z])
    assert [%QuietWindow{}] = Quiet.active(~U[2030-06-13 09:10:00.000000Z])
  end

  test "a window that crosses midnight belongs to the day it started" do
    la()
    m = machine("attic")
    s = daily(m, "23:30", "2h")

    Quiet.tick(~U[2030-06-13 07:15:00.000000Z])
    assert [%QuietWindow{until: until}] = Quiet.active(~U[2030-06-13 07:15:00.000000Z])
    assert DateTime.diff(until, ~U[2030-06-13 08:30:00.000000Z]) == 0
    assert Repo.get!(QuietSchedule, s.id).last_started_on == ~D[2030-06-12]

    end_windows()
    Quiet.tick(~U[2030-06-13 07:20:00.000000Z])
    assert Quiet.active(~U[2030-06-13 07:20:00.000000Z]) == []

    Quiet.tick(~U[2030-06-14 06:31:00.000000Z])
    assert [%QuietWindow{}] = Quiet.active(~U[2030-06-14 06:31:00.000000Z])
    assert Repo.get!(QuietSchedule, s.id).last_started_on == ~D[2030-06-13]
  end

  test "a time the clocks skip or repeat is the first valid instant" do
    la()
    m = machine("attic")
    daily(m, "02:30", "30m")
    daily(m, "01:30", "30m")

    assert [%{next: skipped}, _] = QuietSchedules.list(m.id, ~U[2030-03-10 08:00:00.000000Z])
    assert DateTime.compare(skipped, ~U[2030-03-10 10:00:00.000000Z]) == :eq
    assert [_, %{next: repeated}] = QuietSchedules.list(m.id, ~U[2030-11-03 07:00:00.000000Z])
    assert DateTime.compare(repeated, ~U[2030-11-03 08:30:00.000000Z]) == :eq
  end

  test "a window that is running is replaced only by a scheduled one that ends later" do
    m = machine("attic")
    now = DateTime.utc_now()
    before = DateTime.add(now, -3600)
    at = fn -> DateTime.to_iso8601(DateTime.add(now, -10)) end

    Quiet.start(m.id, %{"for" => "4h", "reason" => "by hand"}, "ana")
    schedule!(m, %{"repeat" => "once", "at" => at.(), "for" => "1h"}, before)
    Quiet.tick(now)
    assert [%QuietWindow{reason: "by hand", hold: false}] = Quiet.active(now)
    assert Repo.all(QuietSchedule) == []

    Quiet.start(m.id, %{"for" => "15m", "reason" => "by hand"}, "ana")
    schedule!(m, %{"repeat" => "once", "at" => at.(), "for" => "1h", "reason" => "plan"}, before)
    Quiet.tick(now)
    assert [%QuietWindow{reason: "plan", hold: true}] = Quiet.active(now)
    assert Enum.any?(Quiet.history(m.id), &(&1.ended_by == "replaced by schedule (ana)"))
  end

  test "a held window stays when the machine is back, and a normal one ends" do
    for hold <- [false, true] do
      m = machine("attic-#{hold}", 200)
      service = Repo.insert!(%Service{machine_id: m.id, slug: "web", name: "web"})

      c =
        Repo.insert!(%Check{
          service_id: service.id,
          name: "up",
          type: :http,
          fail_after: 1,
          state: :ok,
          checked_at: DateTime.add(DateTime.utc_now(), -300),
          config: %{"every_seconds" => 60}
        })

      Quiet.start(m.id, %{"for" => "30m"}, "x", hold: hold)
      Quiet.tick(DateTime.utc_now())
      Repo.update!(Ecto.Changeset.change(m, last_seen_at: DateTime.add(DateTime.utc_now(), 1)))
      Issues.record(Repo.get!(Check, c.id), :down, at: DateTime.add(DateTime.utc_now(), 2))
      Quiet.tick(DateTime.utc_now())

      assert length(Quiet.active() |> Enum.filter(&(&1.machine_id == m.id))) ==
               if(hold, do: 1, else: 0)
    end
  end

  test "a schedule that is not good is refused with a sentence" do
    m = machine("attic")
    ok = %{"repeat" => "daily", "time" => "02:00", "for" => "30m"}
    add = &QuietSchedules.add(m.id, &1, "ana", ~U[2030-06-01 00:00:00.000000Z])

    assert {:ok, _} = add.(ok)

    for bad <- ["5h", "0", "soon", nil],
        do: assert({:error, "bad_duration", _} = add.(%{ok | "for" => bad}))

    for bad <- [
          %{ok | "repeat" => "monthly"},
          %{ok | "time" => "25:00"},
          %{ok | "time" => "2am"},
          Map.delete(ok, "time"),
          %{ok | "repeat" => "weekly"},
          Map.merge(ok, %{"repeat" => "weekly", "days" => [8]}),
          %{"repeat" => "once", "at" => "2030-05-01T00:00:00Z", "for" => "1h"},
          %{"repeat" => "once", "at" => "tomorrow", "for" => "1h"},
          %{"repeat" => "once", "for" => "1h"}
        ] do
      assert {:error, "bad_schedule", text} = add.(bad)
      assert is_binary(text)
    end

    assert {:error, "not_found", _} =
             QuietSchedules.add(Ecto.UUID.generate(), ok, "ana", ~U[2030-06-01 00:00:00.000000Z])
  end

  test "the API lists, adds and removes schedules, each with the scope it needs" do
    m = machine("attic")
    act = token(~w(act))
    read = token(~w(read))
    path = "/api/v1/machines/#{m.id}/quiet/schedules"

    body = %{
      "repeat" => "weekly",
      "time" => "02:00",
      "days" => [1, 3],
      "for" => "30m",
      "reason" => "nightly update"
    }

    assert as(read, :post, path, body) |> json_response(403)

    assert %{
             "id" => id,
             "repeat" => "weekly",
             "at" => nil,
             "time" => "02:00",
             "days" => [1, 3],
             "for_seconds" => 1800,
             "reason" => "nightly update",
             "by" => "token ops",
             "next" => next
           } = as(act, :post, path, body) |> json_response(200)

    assert {:ok, _, 0} = DateTime.from_iso8601(next)

    assert %{"items" => [%{"id" => ^id}], "next" => nil} =
             as(read, :get, path) |> json_response(200)

    assert as(token(~w(admin)), :get, path) |> json_response(403)

    assert %{"schedules" => [%{"id" => ^id}]} =
             as(read, :get, "/api/v1/machines/#{m.id}") |> json_response(200)

    assert %{"error" => %{"code" => "bad_schedule"}} =
             as(act, :post, path, %{body | "time" => "late"}) |> json_response(422)

    assert %{"error" => %{"code" => "bad_duration"}} =
             as(act, :post, path, %{body | "for" => "9h"}) |> json_response(422)

    assert as(act, :post, "/api/v1/machines/#{Ecto.UUID.generate()}/quiet/schedules", body)
           |> json_response(404)

    assert as(read, :delete, "#{path}/#{id}") |> json_response(403)
    assert %{"ok" => true} = as(act, :delete, "#{path}/#{id}") |> json_response(200)
    assert as(act, :delete, "#{path}/#{id}") |> json_response(404)
    assert %{"items" => []} = as(read, :get, path) |> json_response(200)
  end

  defp page(m) do
    service = Repo.insert!(%Service{machine_id: m.id, slug: "machine", name: "Machine"})
    live(signed_in(build_conn()), "/s/#{service.id}")
  end

  test "the machine's page schedules a one-off in the night time zone" do
    la()
    m = machine("attic")
    {:ok, view, html} = page(m)
    assert html =~ "schedule-form-#{m.id}"
    assert html =~ ~r/When \(P[SD]T\)/

    view
    |> form("#schedule-form-#{m.id}",
      schedule: %{at: "2031-03-04T21:00", for: "2h", reason: "Windows updates"}
    )
    |> render_submit()

    assert [%QuietSchedule{repeat: "once", seconds: 7200, by: "sam", at: at}] =
             Repo.all(QuietSchedule)

    assert DateTime.diff(at, ~U[2031-03-05 05:00:00.000000Z]) == 0
    html = render(view)
    assert html =~ "Once on Mar 4 at 21:00 PST for 2h: Windows updates"
    assert html =~ "Next start Mar 4 21:00 PST"
  end

  test "the machine's page schedules a weekly window" do
    m = machine("attic")
    {:ok, view, html} = page(m)
    assert html =~ "When (UTC)"
    refute html =~ "schedule[days][]"

    view |> form("#schedule-form-#{m.id}", schedule: %{repeat: "weekly"}) |> render_change()
    assert render(view) =~ "schedule[days][]"

    view
    |> form("#schedule-form-#{m.id}",
      schedule: %{time: "02:00", for: "30m", days: ["1", "3"], reason: "nightly update"}
    )
    |> render_submit()

    assert [%QuietSchedule{repeat: "weekly", time: "02:00", days: [1, 3], seconds: 1800}] =
             Repo.all(QuietSchedule)

    assert render(view) =~ "Every Mon, Wed at 02:00 UTC for 30m: nightly update"
  end

  test "a schedule that is refused says why beside the form, and Remove removes one" do
    m = machine("attic")
    {:ok, view, _} = page(m)

    view |> form("#schedule-form-#{m.id}", schedule: %{at: "", for: "1h"}) |> render_submit()
    assert render(view) =~ "Choose a date and time that is still to come."
    assert Repo.all(QuietSchedule) == []

    view
    |> form("#schedule-form-#{m.id}", schedule: %{at: "2031-03-04T21:00", for: "1h"})
    |> render_submit()

    refute render(view) =~ "Choose a date and time that is still to come."
    [s] = Repo.all(QuietSchedule)
    assert has_element?(view, "#schedule-#{s.id}")

    view |> element("#schedule-#{s.id} button", "Remove") |> render_click()
    assert Repo.all(QuietSchedule) == []
    refute has_element?(view, "#schedule-#{s.id}")
  end
end
