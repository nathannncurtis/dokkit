defmodule DokkitWeb.MachinePageTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Dokkit.{Machine, Repo, Service, User}

  setup %{conn: conn} do
    m =
      Repo.insert!(%Machine{
        name: "vault",
        kind: :enrolled,
        last_seen_at: DateTime.utc_now(),
        has_updater: true,
        program_version: "v1.0.0",
        updater_version: "v1.0.0"
      })

    own =
      Repo.insert!(%Service{
        machine_id: m.id,
        slug: "machine",
        name: "The machine itself",
        state: :ok
      })

    web = Repo.insert!(%Service{machine_id: m.id, slug: "web", name: "Web", state: :down})

    Repo.insert!(%Service{
      machine_id: m.id,
      slug: "old",
      name: "Old thing",
      state: :ok,
      watched: false
    })

    apps = Repo.insert!(%Machine{name: "Apps", kind: :group})

    app =
      Repo.insert!(%Service{
        machine_id: apps.id,
        slug: "tool",
        name: "Tool",
        kind: :app,
        state: :unknown
      })

    seen =
      Repo.insert!(%Service{
        machine_id: apps.id,
        slug: "viewer",
        name: "Viewer",
        kind: :app,
        state: :ok
      })

    %{conn: signed_in(conn), m: m, own: own, web: web, app: app, seen: seen, apps: apps}
  end

  defp viewer(conn) do
    user = Repo.insert!(%User{name: "vic", password_hash: "-", role: :viewer})

    Plug.Test.init_test_session(conn, %{
      "user_id" => user.id,
      "signed_at" => Dokkit.Accounts.stamp()
    })
  end

  test "the page shows its cards for a machine", %{conn: conn, m: m, web: web} do
    {:ok, view, html} = live(conn, "/machines/#{m.id}")
    assert has_element?(view, "h1", "vault")
    assert html =~ "Up"

    for id <- ~w(meters history processes services downtime issues versions silent-form),
        do: assert(has_element?(view, "##{id}"), id)

    assert has_element?(view, "#services a[href='/s/#{web.id}']", "Web")
    refute has_element?(view, "#services", "Old thing")
    assert has_element?(view, "#quiet-form-#{m.id}")
    assert has_element?(view, "#schedule-form-#{m.id}")
    assert has_element?(view, "#look-again")
    assert has_element?(view, "#services a", "Open Found")
  end

  test "services come in groups with trouble first", %{conn: conn, m: m} do
    {:ok, _, html} = live(conn, "/machines/#{m.id}")
    assert :binary.match(html, ~s(bare">Needs a look)) < :binary.match(html, ~s(bare">Fine))
  end

  test "an owner can update; a viewer sees no owner controls", %{conn: conn, m: m} do
    dir =
      Path.join(System.tmp_dir!(), "dokkit-rel-#{Base.encode16(:crypto.strong_rand_bytes(6))}")

    old = Application.get_env(:dokkit, :releases)
    Application.put_env(:dokkit, :releases, dir)
    on_exit(fn -> Application.put_env(:dokkit, :releases, old) end)
    File.mkdir_p!(Path.join(dir, "v1.1.0"))
    for f <- ~w(SHA256SUMS SHA256SUMS.sig), do: File.write!(Path.join([dir, "v1.1.0", f]), "x")

    {:ok, view, _} = live(conn, "/machines/#{m.id}")
    assert has_element?(view, "#update button", "Update to v1.1.0")

    {:ok, other, _} = live(viewer(build_conn()), "/machines/#{m.id}")
    refute has_element?(other, "#update button")
    assert has_element?(other, "#look-again[disabled]")
    assert has_element?(other, ~s|#silent-form button[type=submit][disabled]|)

    view |> element("#update button") |> render_click()
    assert Repo.get!(Machine, m.id).wanted_version == "v1.1.0"
    send(view.pid, {:settled, :shell})
    assert has_element?(view, "#updating h1", "Updating to v1.1.0")
  end

  test "the sidebar and Everything link to the machine page, old anchors still exist", %{
    conn: conn,
    m: m
  } do
    {:ok, view, _} = live(conn, "/all")
    assert has_element?(view, "nav a[href='/machines/#{m.id}']")
    assert has_element?(view, "#mh-#{m.id} a[href='/machines/#{m.id}']")
    assert has_element?(view, "#m-#{m.id}")
  end

  test "an issue row links to the machine", %{conn: conn, m: m} do
    Repo.insert!(%Dokkit.Issue{
      machine_id: m.id,
      kind: "machine",
      state: :down,
      title: "vault stopped reporting",
      since: DateTime.utc_now()
    })

    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "a.tag[href='/machines/#{m.id}']", "vault")
  end

  test "the moved cards are gone from the machine's service page", %{conn: conn, own: own, m: m} do
    {:ok, view, _} = live(conn, "/s/#{own.id}")

    for id <- ~w(processes history silent-form downtime),
        do: refute(has_element?(view, "##{id}"), id)

    assert has_element?(view, "#machine-page[href='/machines/#{m.id}']")
  end

  test "the sidebar lists real machines only and Apps has its own entry", %{
    conn: conn,
    m: m,
    apps: apps
  } do
    {:ok, view, _} = live(conn, "/all")
    assert has_element?(view, "nav a[href='/apps']", "Apps")
    refute has_element?(view, "nav a[href='/machines/#{apps.id}']")
    assert has_element?(view, "nav a[href='/machines/#{m.id}']", "vault")
  end

  test "Apps lists the group services, silent ones apart, and Everything links to it", %{
    conn: conn,
    app: app,
    seen: seen
  } do
    {:ok, view, html} = live(conn, "/apps")
    assert has_element?(view, "a[href='/s/#{seen.id}']", "Viewer")
    assert has_element?(view, "#no-signal")
    assert has_element?(view, "a[href='/s/#{app.id}']", "Tool")
    assert :binary.match(html, "Viewer") < :binary.match(html, "No signal yet")
    assert :binary.match(html, "No signal yet") < :binary.match(html, "Tool")

    {:ok, all, _} = live(conn, "/all")
    assert has_element?(all, ".grp a[href='/apps']", "Apps")
  end

  test "a missing machine or a group goes elsewhere", %{conn: conn, apps: apps} do
    assert {:error, {:live_redirect, %{to: "/all"}}} =
             live(conn, "/machines/#{Ecto.UUID.generate()}")

    assert {:error, {:live_redirect, %{to: "/apps"}}} = live(conn, "/machines/#{apps.id}")
  end
end
