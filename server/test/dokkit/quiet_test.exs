defmodule Dokkit.QuietTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Dokkit.{Alerts, Check, Issues, Keys, Machine, Quiet, QuietWindow, Repo, Service, Watch}

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

  defp key(m), do: elem(Keys.mint(:machine, %{machine_id: m.id}), 0)
  defp token(scopes), do: elem(Keys.mint(:user, %{scopes: scopes, label: "ops"}), 0)

  defp check(m, name \\ "web", type \\ :http) do
    service = Repo.insert!(%Service{machine_id: m.id, slug: name, name: name})

    Repo.insert!(%Check{
      service_id: service.id,
      name: "up",
      type: type,
      fail_after: 1,
      state: :ok,
      config: %{"every_seconds" => 60}
    })
  end

  defp as(token, verb, path, body \\ nil) do
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

    if body,
      do: dispatch(conn, @endpoint, verb, path, body),
      else: dispatch(conn, @endpoint, verb, path)
  end

  defp minutes(n), do: DateTime.add(DateTime.utc_now(), n * 60)

  test "the machine plans its own downtime, replaces it, and ends it" do
    m = machine("attic")
    other = machine("cellar")
    k = key(m)

    assert %{"ok" => true, "until" => until} =
             as(k, :post, "/api/v1/quiet", %{"for" => "15m", "reason" => "nightly update"})
             |> json_response(200)

    assert DateTime.diff(elem(DateTime.from_iso8601(until), 1), DateTime.utc_now()) in 890..900
    assert [%QuietWindow{by: "machine", reason: "nightly update"}] = Quiet.active()
    assert Quiet.quiet?(m.id)
    refute Quiet.quiet?(other.id)

    as(k, :post, "/api/v1/quiet", %{"for" => "1h"}) |> json_response(200)
    assert [%QuietWindow{reason: nil}] = Quiet.active()
    assert [%{ended_by: nil}, %{ended_by: "replaced by machine"}] = Quiet.history(m.id)

    assert %{"until" => nil} =
             as(k, :post, "/api/v1/quiet", %{"for" => "0"}) |> json_response(200)

    assert Quiet.active() == []
    assert Enum.any?(Quiet.history(m.id), &(&1.ended_by == "machine"))
  end

  test "a window is at most four hours and a bad length is refused" do
    k = key(machine("attic"))

    assert as(k, :post, "/api/v1/quiet", %{"for" => "4h"}) |> json_response(200)

    assert %{"error" => %{"code" => "bad_duration"}} =
             as(k, :post, "/api/v1/quiet", %{"for" => "241m"}) |> json_response(422)

    for bad <- ["5h", "soon", "", "-5m", "1d", nil] do
      assert as(k, :post, "/api/v1/quiet", %{"for" => bad}) |> json_response(422)
    end

    assert as(k, :post, "/api/v1/quiet", %{}) |> json_response(422)
  end

  test "a machine key quiets only its own machine, and an app key not at all" do
    m = machine("attic")
    other = machine("cellar")
    k = key(m)

    assert as(k, :post, "/api/v1/machines/#{other.id}/quiet", %{"for" => "15m"})
           |> json_response(401)

    as(k, :post, "/api/v1/quiet", %{"for" => "15m", "machine" => other.id}) |> json_response(200)
    assert [%QuietWindow{machine_id: id}] = Quiet.active()
    assert id == m.id

    {app, _} = Keys.mint(:app, %{})
    assert as(app, :post, "/api/v1/quiet", %{"for" => "15m"}) |> json_response(401)
    assert build_conn() |> post("/api/v1/quiet", %{"for" => "15m"}) |> json_response(401)
  end

  test "a person's token plans and ends downtime, and it is kept in the machine's history" do
    m = machine("attic")
    act = token(~w(act))

    assert %{"planned_downtime" => %{"reason" => "disks", "by" => "token ops"}} =
             as(act, :post, "/api/v1/machines/#{m.id}/quiet", %{
               "for" => "30m",
               "reason" => "disks"
             })
             |> json_response(200)

    assert as(token(~w(read)), :post, "/api/v1/machines/#{m.id}/quiet", %{"for" => "30m"})
           |> json_response(403)

    assert %{"planned_downtime" => nil} =
             as(act, :delete, "/api/v1/machines/#{m.id}/quiet") |> json_response(200)

    assert %{
             "downtime_history" => [
               %{"by" => "token ops", "ended_by" => "token ops", "reason" => "disks"}
             ]
           } =
             as(token(~w(read)), :get, "/api/v1/machines/#{m.id}") |> json_response(200)

    assert as(act, :post, "/api/v1/machines/#{Ecto.UUID.generate()}/quiet", %{"for" => "5m"})
           |> json_response(404)

    assert as(act, :post, "/api/v1/machines/nonsense/quiet", %{"for" => "5m"})
           |> json_response(404)
  end

  test "the sweep opens no machine issue inside a window, and opens it when the window ends" do
    m = machine("attic", 600)
    Quiet.start(m.id, %{"for" => "15m", "reason" => "nightly update"}, "machine")
    now = DateTime.utc_now()

    assert Issues.machines_sweep(now) == 0
    assert Issues.open_list() == []

    after_window = DateTime.add(now, 16 * 60)
    assert Issues.machines_sweep(after_window) == 1

    assert [%{title: "attic stopped reporting", notes: [%{"text" => text}]}] = Issues.open_list()
    assert text =~ "Planned downtime ended at"
    assert text =~ "(nightly update)"
  end

  test "a machine that stopped before any window gets no planned note" do
    m = machine("attic", 600)
    Quiet.start(m.id, %{"for" => "5m"}, "machine")
    Repo.update_all(QuietWindow, set: [started_at: minutes(-90), until: minutes(-85)])
    Repo.update!(Ecto.Changeset.change(m, last_seen_at: minutes(-30)))

    assert Issues.machines_sweep(DateTime.utc_now()) == 1
    assert [%{notes: []}] = Issues.open_list()
  end

  test "a window ended by a person lets the silent machine be reported at once" do
    m = machine("attic", 600)
    Quiet.start(m.id, %{"for" => "1h"}, "ana")
    assert Issues.machines_sweep(DateTime.utc_now()) == 0
    Quiet.stop(m.id, "ana")
    assert Issues.machines_sweep(DateTime.utc_now()) == 1
    assert [%{notes: [%{"text" => "Planned downtime ended" <> _}]}] = Issues.open_list()
  end

  test "checks going down inside a window open nothing, and count again after it" do
    m = machine("attic")
    c = check(m)
    Quiet.start(m.id, %{"for" => "15m"}, "machine")

    Issues.record(c, :down, note: "refused")
    assert Issues.open_list() == []
    assert Repo.get!(Check, c.id).state == :ok
    assert Repo.get!(Check, c.id).checked_at

    Quiet.stop(m.id, "machine")
    Issues.record(Repo.get!(Check, c.id), :down, note: "refused")
    assert [%{title: "web is down"}] = Issues.open_list()
  end

  test "an issue open before the window stays open through it" do
    m = machine("attic")
    c = check(m)
    Issues.record(c, :down, note: "refused")
    [before] = Issues.open_list()

    Quiet.start(m.id, %{"for" => "15m"}, "machine")
    Issues.record(Repo.get!(Check, c.id), :down, note: "still refused")
    Issues.machines_sweep(DateTime.utc_now())

    assert [%{id: id}] = Issues.open_list()
    assert id == before.id
  end

  test "jobs and beats are not judged inside a window, nor for what the window covered" do
    m = machine("attic")
    c = check(m, "pulse", :beat)
    Repo.update!(Ecto.Changeset.change(c, checked_at: minutes(-60)))

    Quiet.start(m.id, %{"for" => "15m"}, "machine")
    assert Watch.sweep(DateTime.utc_now()) == 0

    Quiet.stop(m.id, "machine")
    assert Watch.sweep(DateTime.add(DateTime.utc_now(), 100)) == 0
    assert Watch.sweep(DateTime.add(DateTime.utc_now(), 300)) == 1
  end

  test "the window ends early once the machine was silent, is back, and each check has reported" do
    m = machine("attic", 200)
    c = check(m)
    Repo.update!(Ecto.Changeset.change(c, checked_at: minutes(-5)))
    Quiet.start(m.id, %{"for" => "30m"}, "machine")

    Quiet.tick(DateTime.utc_now())
    assert [%QuietWindow{silent_at: %DateTime{}}] = Quiet.active()

    Repo.update!(Ecto.Changeset.change(m, last_seen_at: DateTime.add(DateTime.utc_now(), 1)))
    Quiet.tick(DateTime.utc_now())
    assert [%QuietWindow{}] = Quiet.active()

    Issues.record(Repo.get!(Check, c.id), :down, at: DateTime.add(DateTime.utc_now(), 2))
    assert Repo.get!(Check, c.id).checked_at
    Quiet.tick(DateTime.utc_now())
    assert Quiet.active() == []
    assert [%{ended_by: "machine back"}] = Quiet.history(m.id)
  end

  test "a machine that never went silent keeps its window until its time" do
    m = machine("attic")
    Quiet.start(m.id, %{"for" => "30m"}, "machine")
    Quiet.tick(DateTime.utc_now())
    assert [%QuietWindow{silent_at: nil}] = Quiet.active()
  end

  test "pages say who is in planned downtime, and End now ends it", %{conn: conn} do
    m = machine("attic")
    Quiet.start(m.id, %{"for" => "15m", "reason" => "nightly update"}, "machine")

    {:ok, _, html} = live(signed_in(conn), "/")
    assert html =~ "1 machine in planned downtime"

    {:ok, view, html} = live(signed_in(conn), "/all")
    assert html =~ "Planned downtime until"
    assert html =~ "nightly update"
    assert html =~ "Alerts for this machine are off until then."

    render_click(view, "quiet_end", %{"machine" => m.id})
    assert Quiet.active() == []
    refute render(view) =~ "Alerts for this machine are off"
    {:ok, _, html} = live(signed_in(conn), "/")
    refute html =~ "in planned downtime"
  end

  test "the machine's page starts a window" do
    m = machine("attic")
    service = Repo.insert!(%Service{machine_id: m.id, slug: "machine", name: "Machine"})
    {:ok, view, html} = live(signed_in(build_conn()), "/s/#{service.id}")
    assert html =~ "quiet-form-#{m.id}"

    view
    |> form("#quiet-form-#{m.id}", quiet: %{for: "1h", reason: "reboot"})
    |> render_submit()

    assert [%QuietWindow{reason: "reboot", by: "sam"}] = Quiet.active()
    assert render(view) =~ "Planned downtime until"
  end

  test "the day marks the window on the machine's lane" do
    m = machine("attic")
    Quiet.start(m.id, %{"for" => "1h"}, "machine")
    assert %{machines: [%{cells: cells}]} = Dokkit.Read.day()
    assert "planned" in cells
  end
end
