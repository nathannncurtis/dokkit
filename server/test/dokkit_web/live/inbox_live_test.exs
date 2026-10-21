defmodule DokkitWeb.InboxLiveTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias Dokkit.{Check, Intake, Keys, Machine, Repo, Service, Watch}

  setup do
    machine = Repo.insert!(%Machine{name: "vault"})

    service =
      Repo.insert!(%Service{
        machine_id: machine.id,
        slug: "backup",
        name: "Nightly backup",
        kind: :job
      })

    %{service: service}
  end

  setup %{conn: conn}, do: %{conn: signed_in(conn)}

  test "nobody gets in without signing in" do
    assert redirected_to(get(build_conn(), "/")) == "/login"
  end

  test "the inbox shows a failed job as it happens and clears when it recovers", %{
    conn: conn,
    service: service
  } do
    {_, key} = Keys.mint(:app, %{service_id: service.id})
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Nothing here needs you"

    Intake.ping(key, "backup", "fail", nil, "")
    assert render(view) =~ "Nightly backup failed"
    assert render(view) =~ "1 needs a look"

    Intake.ping(key, "backup", "ok", nil, "")
    send(view.pid, {:settled, :page})
    assert render(view) =~ "Nothing here needs you"
  end

  test "a job that misses its time becomes an issue once, and a late run closes it", %{
    conn: conn,
    service: service
  } do
    check =
      Repo.insert!(%Check{
        service_id: service.id,
        name: "backup",
        type: :job,
        fail_after: 1,
        config: %{"schedule" => "0 1 * * *", "grace" => "30m"},
        inserted_at: ~U[2026-10-01 00:00:00.000000Z]
      })

    assert Watch.sweep(~U[2026-10-06 01:20:00.000000Z]) == 0
    assert Watch.sweep(~U[2026-10-06 01:31:00.000000Z]) == 1
    assert Watch.sweep(~U[2026-10-06 01:32:00.000000Z]) == 0

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Nightly backup did not run"
    assert html =~ "Expected at 01:00 UTC"

    {_, key} = Keys.mint(:app, %{service_id: service.id})
    Intake.ping(key, "backup", "ok", nil, "")
    assert Repo.get!(Check, check.id).state == :ok
  end

  test "durations" do
    assert Watch.seconds("30m", 0) == 1800
    assert Watch.seconds("2h", 0) == 7200
    assert Watch.seconds("soon", 5) == 5
  end

  test "snoozing takes an issue out of the inbox until it is brought back", %{
    conn: conn,
    service: service
  } do
    {_, key} = Keys.mint(:app, %{service_id: service.id})
    Intake.ping(key, "backup", "fail", nil, "")
    {:ok, view, _} = live(conn, "/")
    [issue] = Dokkit.Issues.open_list()

    view |> element("#issue-#{issue.id} input.chk") |> render_click()
    html = view |> element("button", "Snooze selected") |> render_click()
    assert html =~ "Nothing here needs you"
    assert Dokkit.Issues.open_count() == 0
    assert [%{id: id}] = Dokkit.Issues.snoozed_list()
    assert id == issue.id

    html = view |> element("button[phx-value-tab=snoozed]") |> render_click()
    assert html =~ "Nightly backup failed"
    html = view |> element("#issue-#{issue.id} button[phx-click=back]") |> render_click()
    assert html =~ "Nothing is snoozed"
    assert Dokkit.Issues.open_count() == 1

    {:ok, page, html} = live(conn, "/s/#{service.id}")
    assert html =~ "Mark as seen"
    assert render_click(page, "seen") =~ "Seen"
    assert render_click(page, "snooze") =~ "Snoozed until"
    assert render_click(page, "back") =~ "Snooze for a day"
  end

  test "the service page stops and starts watching, holds a version and allows a restart", %{
    conn: conn,
    service: service
  } do
    Repo.insert!(%Check{
      service_id: service.id,
      name: "svc",
      type: :"windows-service",
      config: %{"name" => "Spooler"}
    })

    {:ok, view, html} = live(conn, "/s/#{service.id}")
    assert html =~ "Stop watching"

    assert render_click(view, "watching") =~ "Watch again"
    refute Repo.get!(Dokkit.Service, service.id).watched
    {:ok, _, all} = live(conn, "/all")
    assert all =~ "Not watched"
    assert render_click(view, "watching") =~ "Stop watching"

    render_submit(view, "hold", %{"version" => " 1.4.2 "})
    assert Repo.get!(Dokkit.Service, service.id).held == "1.4.2"

    assert render_click(view, "restart") =~ "Stop starting it again"
    assert [%{restart: true}] = Dokkit.Found.checks(service.machine_id)
  end

  test "a note is added to the open issue from its service page", %{conn: conn, service: service} do
    {_, key} = Keys.mint(:app, %{service_id: service.id})
    Intake.ping(key, "backup", "fail", nil, "")
    {:ok, view, html} = live(conn, "/s/#{service.id}")
    assert html =~ "What you found or did"

    html = view |> form("#note-form", text: " Disk was full; cleared it ") |> render_submit()
    assert html =~ "Disk was full; cleared it"
    assert html =~ "sam,"
  end

  defp bad_check(machine, name, env, type, state, opts \\ []) do
    s =
      Repo.insert!(%Service{machine_id: machine.id, slug: name, name: name, environment: env})

    c = Repo.insert!(%Check{service_id: s.id, name: name, type: type, fail_after: 1})
    {s, Dokkit.Issues.record(c, state, opts)}
  end

  test "a degraded expiry is soon, not needs you, and stops being soon when it goes down" do
    m = Repo.insert!(%Machine{name: "inbox-soon"})
    {_, check} = bad_check(m, "cert", "production", :expiry, :degraded)
    assert %{needs_you: [], soon: [%{title: "cert is degraded"}]} = Dokkit.Read.inbox()

    Dokkit.Issues.record(check, :down)
    assert %{needs_you: [%{soon: false}], soon: []} = Dokkit.Read.inbox()
  end

  test "a soon issue never takes the down route" do
    m = Repo.insert!(%Machine{name: "inbox-route"})
    s = Repo.insert!(%Service{machine_id: m.id, slug: "disk", name: "disk"})
    c = Repo.insert!(%Check{service_id: s.id, name: "disk", type: :custom, fail_after: 1})
    Dokkit.Issues.record(c, :degraded, soon: true)
    [issue] = Dokkit.Issues.open_list()
    assert issue.soon
    assert Repo.get_by!(Dokkit.Alert, issue_id: issue.id).channel == "push"
  end

  test "found things are under Not watched and can be watched or left from the first screen", %{
    conn: conn
  } do
    m = Repo.insert!(%Machine{name: "inbox-found"})

    for {key, label} <- [{"5432", "Port 5432"}, {"6379", "Port 6379"}] do
      Repo.insert!(%Dokkit.Finding{
        machine_id: m.id,
        kind: "port",
        key: key,
        detail: %{"label" => label, "saw" => "Listening"}
      })
    end

    {:ok, view, html} = live(conn, "/")
    assert html =~ "Not watched"
    html = view |> element("button[phx-value-tab=found]") |> render_click()
    assert html =~ "Port 5432" and html =~ "Port 6379"

    [a, b] = Dokkit.Found.list()
    html = view |> element("#found-#{a.id} button", "Watch it") |> render_click()
    refute html =~ a.detail["label"] <> "</span>"
    assert Repo.get_by(Service, machine_id: m.id, slug: "port-" <> a.key)
    view |> element("#found-#{b.id} button", "Leave it") |> render_click()
    assert Dokkit.Found.count() == 0
  end

  test "a row opens to snooze for an hour or mark as seen, and email shows as Emailed", %{
    conn: conn,
    service: service
  } do
    {_, key} = Keys.mint(:app, %{service_id: service.id})
    Intake.ping(key, "backup", "fail", nil, "")
    [issue] = Dokkit.Issues.open_list()

    Repo.update!(
      Ecto.Changeset.change(Repo.get_by!(Dokkit.Alert, issue_id: issue.id),
        channel: "email",
        status: :sent
      )
    )

    {:ok, view, html} = live(conn, "/")
    assert html =~ "<details"
    assert html =~ "Emailed"
    refute html =~ "Webhook called"

    html = view |> element("#issue-#{issue.id} button", "Mark as seen") |> render_click()
    assert html =~ "Seen"
    assert Repo.get!(Dokkit.Issue, issue.id).acknowledged_at

    view |> element("#issue-#{issue.id} button", "Snooze an hour") |> render_click()
    assert [%{id: id}] = Dokkit.Issues.snoozed_list()
    assert id == issue.id
  end

  test "the fine line counts watched services that reported fine, and the machines", %{
    conn: conn,
    service: service
  } do
    {:ok, _, html} = live(conn, "/")
    refute html =~ "Everything else is fine: 1 service"

    check =
      Repo.insert!(%Check{service_id: service.id, name: "backup", type: :job, fail_after: 1})

    Dokkit.Issues.record(check, :ok)

    {:ok, _, html} = live(conn, "/")
    assert html =~ "Everything else is fine: 1 service on 1 machine."
    assert %{fine: %{services: 1, machines: 1}} = Dokkit.Read.inbox()
  end

  test "another environment stays out of Needs you and shows in its own group", %{conn: conn} do
    m = Repo.insert!(%Machine{name: "inbox-env"})
    bad_check(m, "staging-api", "dev", :custom, :down)

    assert %{needs_you: [], other_environments: [%{environment: "dev", issues: [_]}]} =
             Dokkit.Read.inbox()

    {:ok, _, html} = live(conn, "/")
    assert html =~ "Nothing here needs you"
    assert html =~ ~r/class="grp">\s*dev/
    assert html =~ "staging-api"
  end

  test "a down issue shows a circle, a degraded one a diamond, and a count of one is left out", %{
    conn: conn
  } do
    m = Repo.insert!(%Machine{name: "inbox-shape"})
    {_, down} = bad_check(m, "api-down", "production", :custom, :down)
    bad_check(m, "api-slow", "production", :custom, :degraded)

    {:ok, _, html} = live(conn, "/")
    assert html =~ ~r/class="lvl bad"[^>]*aria-label="Down"/
    assert html =~ ~r/class="lvl warn"[^>]*aria-label="Needs a look"/
    refute html =~ "<small>"

    Repo.update_all(from(i in Dokkit.Issue, where: i.check_id == ^down.id), set: [count: 3])
    {:ok, _, html} = live(conn, "/")
    assert html =~ "3<small>times</small>"
  end

  test "an opened row and the tab are kept across live updates", %{conn: conn, service: service} do
    {_, key} = Keys.mint(:app, %{service_id: service.id})
    Intake.ping(key, "backup", "fail", nil, "")
    [issue] = Dokkit.Issues.open_list()

    {:ok, view, html} = live(conn, "/")
    assert html =~ ~r/<details[^>]*id="issue-#{issue.id}-open"[^>]*ignore_attrs/
    refute html =~ ~r/<summary[^>]*>[^<]*<input/

    view |> element("button[phx-value-tab=soon]") |> render_click()
    send(view.pid, {:settled, :page})
    assert has_element?(view, "#tab-soon[aria-selected=true]")
    assert has_element?(view, "#tab-soon[aria-controls=inbox-panel]")
    assert has_element?(view, "#inbox-panel[role=tabpanel]")
  end

  test "a machine counts only what is under Needs you; Soon reads soon", %{conn: conn} do
    m = Repo.insert!(%Machine{name: "inbox-count"})
    bad_check(m, "cert", "production", :expiry, :degraded)
    {:ok, _, html} = live(conn, "/")
    assert html =~ "1 soon"
    refute html =~ "1 needs a look"

    d = Repo.insert!(%Machine{name: "inbox-dev"})
    bad_check(d, "staging", "dev", :custom, :down)
    {:ok, _, html} = live(conn, "/")
    refute html =~ "1 needs a look"
  end

  test "the job timing form keeps what was typed until it is saved", %{
    conn: conn,
    service: service
  } do
    Repo.insert!(%Check{service_id: service.id, name: "backup", type: :job, config: %{}})
    {:ok, view, _} = live(conn, "/s/#{service.id}")

    html = view |> form("#timing-form", timing: %{grace: "45m"}) |> render_change()
    assert html =~ ~s(value="45m")
    html = view |> form("#timing-form", timing: %{max_runtime: "x"}) |> render_change()
    assert html =~ ~s(value="45m")

    html = view |> form("#timing-form") |> render_submit()
    assert html =~ ~s(value="45m")
    assert html =~ ~s(value="x")
    assert html =~ "30m, 2h, 1d"
  end

  test "a burst of changes on the inbox is coalesced into one pending reload", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn), "/")
    for _ <- 1..5, do: send(view.pid, :issues_changed)
    render(view)
    {:dictionary, dict} = Process.info(view.pid, :dictionary)
    assert List.keyfind(dict, {:debounce, :page}, 0) == {{:debounce, :page}, :pending}
  end
end
