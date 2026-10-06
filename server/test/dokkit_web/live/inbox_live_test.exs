defmodule DokkitWeb.InboxLiveTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
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

  test "the inbox shows a failed job as it happens and clears when it recovers", %{
    conn: conn,
    service: service
  } do
    {_, key} = Keys.mint(:app, %{service_id: service.id})
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Nothing needs you"

    Intake.ping(key, "backup", "fail", nil, "")
    assert render(view) =~ "Nightly backup failed"
    assert render(view) =~ "1 needs a look"

    Intake.ping(key, "backup", "ok", nil, "")
    assert render(view) =~ "Nothing needs you"
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
end
