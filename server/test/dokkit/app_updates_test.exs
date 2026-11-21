defmodule Dokkit.AppUpdatesTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias Dokkit.{AppTarget, AppUpdates, Check, Deploy, Estate, Issue, Keys, Machine, Repo, Service}

  @zip "acme-intake-1.4.0-windows-amd64.zip"
  @body "the new acme-intake"

  setup do
    dir =
      Path.join(System.tmp_dir!(), "dokkit-apps-#{Base.encode16(:crypto.strong_rand_bytes(6))}")

    old = Application.get_env(:dokkit, :releases)
    Application.put_env(:dokkit, :releases, dir)

    on_exit(fn ->
      Application.put_env(:dokkit, :releases, old)
      File.rm_rf(dir)
    end)

    build01 = machine("build01")
    {mkey, _} = Keys.mint(:machine, %{machine_id: build01.id})
    {admin, _} = Keys.mint(:user, %{scopes: ["read", "admin"]})
    {act, _} = Keys.mint(:user, %{scopes: ["read", "act"]})
    %{build01: build01, mkey: mkey, admin: admin, act: act}
  end

  defp machine(name, attrs \\ []) do
    Repo.insert!(
      struct!(
        Machine,
        [
          name: name,
          kind: :enrolled,
          os: "windows",
          arch: "amd64",
          has_updater: true,
          last_seen_at: DateTime.utc_now()
        ] ++ attrs
      )
    )
  end

  defp recipe, do: %{"kind" => "windows-service", "name" => "AcmeIntake", "folder" => "C:\\Acme"}

  defp declare(machine, app \\ recipe()) do
    doc = %{"schema" => 1, "service" => %{"id" => "acme-intake", "name" => "Acme intake"}}
    {:ok, service} = Estate.declare(machine.id, if(app, do: Map.put(doc, "app", app), else: doc))
    service
  end

  defp sha(text), do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)

  defp github(test, opts \\ []) do
    sums = Keyword.get(opts, :sums, "#{sha(@body)}  #{@zip}\n")
    tag = Keyword.get(opts, :tag, "v1.4.0")

    Req.Test.stub(Dokkit.Alerts, fn conn ->
      send(test, {:github, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})

      case conn.request_path do
        "/repos/example/acme-intake/releases/latest" ->
          Req.Test.json(conn, %{
            "tag_name" => tag,
            "html_url" => "https://github.com/example/acme-intake/releases/tag/#{tag}",
            "published_at" => "2026-11-19T17:00:00Z",
            "assets" => [
              %{"name" => @zip, "size" => byte_size(@body), "url" => asset(1)},
              %{"name" => "acme-intake-1.4.0-linux-arm64.tar.gz", "size" => 3, "url" => asset(2)},
              %{"name" => "SHA256SUMS", "size" => byte_size(sums), "url" => asset(3)}
            ]
          })

        "/repos/example/acme-intake/releases/assets/1" ->
          Plug.Conn.send_resp(conn, 200, @body)

        "/repos/example/acme-intake/releases/assets/3" ->
          Plug.Conn.send_resp(conn, 200, sums)

        _ ->
          Plug.Conn.send_resp(conn, 404, "{}")
      end
    end)
  end

  defp asset(n), do: "https://api.github.com/repos/example/acme-intake/releases/assets/#{n}"

  defp configure(extra \\ %{}) do
    {:ok, _} =
      AppUpdates.save(
        "acme-intake",
        Map.merge(
          %{
            "repo" => "https://github.com/example/acme-intake",
            "assets" => "windows/amd64 acme-intake-*-windows-amd64.zip"
          },
          extra
        )
      )
  end

  defp call(method, path, token, body \\ nil) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, "/api/v1" <> path, body && Jason.encode!(body))
  end

  defp viewer(conn) do
    user = Repo.insert!(%Dokkit.User{name: "vic", password_hash: "-", role: :viewer})

    Plug.Test.init_test_session(conn, %{
      "user_id" => user.id,
      "signed_at" => Dokkit.Accounts.stamp()
    })
  end

  defp target(machine), do: Repo.get_by(AppTarget, app: "acme-intake", machine_id: machine.id)

  describe "the recipe" do
    test "only the machine's own key keeps an [app] table, and a file without one forgets it",
         %{build01: build01} do
      service = declare(build01)
      assert %AppTarget{recipe: %{"kind" => "windows-service"}} = target(build01)

      {app_key, _} = Keys.mint(:app, %{service_id: service.id})
      declare(build01, nil)
      assert target(build01) == nil

      doc = %{
        "schema" => 1,
        "service" => %{"id" => "acme-intake"},
        "app" => recipe()
      }

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> app_key)
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/declare", Jason.encode!(doc))

      assert json_response(conn, 200)
      assert target(build01) == nil
    end

    test "a recipe the program would refuse is refused with the program's words", %{
      build01: build01
    } do
      doc = %{"schema" => 1, "service" => %{"id" => "acme-intake"}, "app" => %{"kind" => "msi"}}

      assert {:error, "app.kind is one of windows-service, installer, compose, systemd, launchd."} =
               Estate.declare(build01.id, doc)
    end
  end

  describe "settings and the token" do
    test "each setting has a default and a reset, and bad values are refused", %{build01: b} do
      declare(b)
      assert AppUpdates.settings("acme-intake") == AppUpdates.defaults()
      configure(%{"mode" => "automatic", "hold" => "true", "signer" => "Example Software Ltd"})

      v = AppUpdates.view("acme-intake")
      assert v.repo == "example/acme-intake"
      assert v.assets == %{"windows/amd64" => "acme-intake-*-windows-amd64.zip"}
      assert v.changed == ~w(assets hold mode repo signer)

      assert v.require_signature == true
      {:ok, v} = AppUpdates.save("acme-intake", %{"require_signature" => "false"})
      assert v.require_signature == false and "require_signature" in v.changed

      assert {:error, "bad_setting", "require_signature is true or false."} =
               AppUpdates.save("acme-intake", %{"require_signature" => "maybe"})

      {:ok, v} =
        AppUpdates.save("acme-intake", %{"mode" => nil, "hold" => "", "require_signature" => nil})

      assert v.require_signature == true
      assert v.mode == "click" and v.hold == false

      assert {:error, "bad_setting", "mode is click or automatic."} =
               AppUpdates.save("acme-intake", %{"mode" => "sometimes"})

      assert {:error, "bad_setting", "repo is a GitHub repository, owner/name."} =
               AppUpdates.save("acme-intake", %{"repo" => "not a repo"})

      assert {:error, "bad_setting", _} = AppUpdates.save("acme-intake", %{"color" => "red"})
      assert {:error, "bad_setting", _} = AppUpdates.save("acme-intake", %{"assets" => "nope"})
      assert {:error, "not_found", _} = AppUpdates.save("no-such-app", %{})
    end

    test "the token is kept, never shown back, and only an admin token touches it", %{
      admin: admin,
      act: act
    } do
      token = "github_pat_" <> String.duplicate("a1", 20) <> "WXYZ"
      assert json_response(call(:get, "/github-token", act), 403)

      assert %{"github_token" => "set", "ending" => "WXYZ"} =
               json_response(call(:put, "/github-token", admin, %{github_token: token}), 200)

      body = response(call(:get, "/github-token", admin), 200)
      refute body =~ "github_pat_"
      assert AppUpdates.token() == token

      assert %{"error" => %{"code" => "bad_token"}} =
               json_response(call(:put, "/github-token", admin, %{github_token: "x y"}), 422)

      assert %{"github_token" => "not set"} =
               json_response(call(:put, "/github-token", admin, %{github_token: ""}), 200)
    end
  end

  describe "fetching releases" do
    test "the newest release's matching files are kept with their SHA-256, checked against the release's sums",
         %{build01: b} do
      declare(b)
      configure()
      {:ok, _} = AppUpdates.save_token("github_pat_" <> String.duplicate("b2", 20))
      github(self())

      assert {:ok, release} = AppUpdates.fetch("acme-intake")
      assert release.version == "v1.4.0"
      assert %{@zip => %{"sha256" => hash, "checked" => true}} = release.files
      assert hash == sha(@body)
      refute Map.has_key?(release.files, "acme-intake-1.4.0-linux-arm64.tar.gz")
      assert File.read!(Path.join(AppUpdates.dir("acme-intake", "v1.4.0"), @zip)) == @body
      assert_received {:github, "/repos/example/acme-intake/releases/latest", ["Bearer " <> _]}
      assert_received {:github, "/repos/example/acme-intake/releases/assets/1", _}

      assert {:ok, _} = AppUpdates.fetch("acme-intake")
      assert_received {:github, "/repos/example/acme-intake/releases/latest", _}
      refute_received {:github, "/repos/example/acme-intake/releases/assets/1", _}
    end

    test "a file that does not match the release's own checksums is not kept", %{build01: b} do
      declare(b)
      configure()
      github(self(), sums: "#{String.duplicate("0", 64)}  #{@zip}\n")

      assert {:error, "bad_checksum", why} = AppUpdates.fetch("acme-intake")
      assert why =~ "does not match"
      assert AppUpdates.newest("acme-intake") == nil
      assert AppUpdates.view("acme-intake").check_note == why
    end

    test "GitHub refusing is noted, and nothing is held", %{build01: b} do
      declare(b)
      configure()
      Req.Test.stub(Dokkit.Alerts, fn conn -> Plug.Conn.send_resp(conn, 404, "{}") end)
      assert {:error, "no_release", _} = AppUpdates.fetch("acme-intake")

      assert AppUpdates.newest("acme-intake") == nil
      {:ok, _} = AppUpdates.save("acme-intake", %{"repo" => nil})
      assert {:error, "no_repo", _} = AppUpdates.fetch("acme-intake")
    end
  end

  describe "who may receive an update" do
    setup %{build01: b} do
      declare(b)
      configure()
      github(self())
      {:ok, _} = AppUpdates.fetch("acme-intake")
      :ok
    end

    test "a host that only logs through an app key is refused", %{admin: admin} do
      host =
        Repo.insert!(%Machine{name: "laptop7", kind: :seen, last_seen_at: DateTime.utc_now()})

      assert {:error, "not_eligible", why} = AppUpdates.approve("acme-intake", host.id)
      assert why =~ "not a monitored machine"

      assert %{"error" => %{"code" => "not_eligible"}} =
               json_response(
                 call(:post, "/app-updates/acme-intake/update", admin, %{machine: host.id}),
                 422
               )
    end

    test "an enrolled machine without the updater, without a recipe, or silent is refused" do
      no_updater = machine("build02", has_updater: false)
      declare(no_updater)

      assert {:error, "not_eligible", "build02 has no Dokkit updater" <> _} =
               AppUpdates.approve("acme-intake", no_updater.id)

      no_recipe = machine("build03")
      declare(no_recipe, nil)

      assert {:error, "not_eligible", "build03 has no [app] for acme-intake" <> _} =
               AppUpdates.approve("acme-intake", no_recipe.id)

      silent = machine("build04", last_seen_at: DateTime.add(DateTime.utc_now(), -3600))
      declare(silent)

      assert {:error, "not_eligible", "build04 is not reporting" <> _} =
               AppUpdates.approve("acme-intake", silent.id)

      mac = machine("build05", os: "darwin", arch: "arm64")
      declare(mac, %{"kind" => "launchd", "name" => "com.example.intake", "folder" => "/opt/a"})

      assert {:error, "not_eligible", "v1.4.0 of acme-intake has no file for darwin/arm64" <> _} =
               AppUpdates.approve("acme-intake", mac.id)

      assert Repo.aggregate(from(t in AppTarget, where: not is_nil(t.wanted_version)), :count) ==
               0
    end

    test "an app on hold is not updated", %{build01: b} do
      configure(%{"hold" => true})
      assert {:error, "held", _} = AppUpdates.approve("acme-intake", b.id)
      assert {:error, "held", _} = AppUpdates.approve("acme-intake", :all)
    end

    test "an app key and a user token cannot ask for, fetch or report an install", %{
      build01: b,
      admin: admin
    } do
      service = Repo.get_by!(Service, machine_id: b.id, slug: "acme-intake")
      {app_key, _} = Keys.mint(:app, %{service_id: service.id})
      {:ok, 1} = AppUpdates.approve("acme-intake", b.id)

      for token <- [app_key, admin] do
        assert json_response(call(:get, "/update/apps", token), 401)
        assert json_response(call(:get, "/update/apps/acme-intake/v1.4.0/#{@zip}", token), 401)

        assert json_response(
                 call(:post, "/update/apps/result", token, %{
                   service: "acme-intake",
                   version: "v1.4.0",
                   ok: true
                 }),
                 401
               )
      end

      assert target(b).wanted_version == "v1.4.0"
    end
  end

  describe "an install" do
    setup %{build01: b} do
      declare(b)
      configure(%{"signer" => "Example Software Ltd"})
      github(self())
      {:ok, _} = AppUpdates.fetch("acme-intake")
      :ok
    end

    test "the updater gets the job and the file, and a good result is a deploy by Dokkit updater",
         %{build01: b, mkey: mkey, admin: admin} do
      service = Repo.get_by!(Service, machine_id: b.id, slug: "acme-intake")
      Repo.update!(Ecto.Changeset.change(service, version: "v1.3.2"))
      assert json_response(call(:get, "/update/apps", mkey), 200) == %{"items" => []}

      assert %{"ok" => true, "machines" => 1} =
               json_response(call(:post, "/app-updates/acme-intake/update", admin, %{}), 200)

      assert %{"items" => [item]} =
               json_response(call(:get, "/update/apps?os=windows&arch=amd64", mkey), 200)

      assert item == %{
               "service" => "acme-intake",
               "version" => "v1.4.0",
               "kind" => "windows-service",
               "file" => @zip,
               "sha256" => sha(@body),
               "size" => byte_size(@body),
               "signer" => "Example Software Ltd",
               "require_signature" => true,
               "health_seconds" => 300
             }

      assert target(b).asked_at
      assert response(call(:get, "/update/apps/acme-intake/v1.4.0/#{@zip}", mkey), 200) == @body
      assert json_response(call(:get, "/update/apps/acme-intake/v1.3.0/#{@zip}", mkey), 404)

      assert json_response(
               call(:post, "/update/apps/result", mkey, %{
                 service: "acme-intake",
                 version: "v9.9.9",
                 ok: true
               }),
               422
             )

      assert %{"ok" => true} =
               json_response(
                 call(:post, "/update/apps/result", mkey, %{
                   service: "acme-intake",
                   version: "v1.4.0",
                   ok: true,
                   note: "installed v1.4.0; checks ok after 12 s"
                 }),
                 200
               )

      assert [%Deploy{from: "v1.3.2", version: "v1.4.0", by: "Dokkit updater", how: "updated"}] =
               Repo.all(Deploy)

      assert Repo.reload!(service).version == "v1.4.0"
      assert %{wanted_version: nil, ok: true} = target(b)
      assert json_response(call(:get, "/update/apps", mkey), 200) == %{"items" => []}
      assert [%{state: "done", behind: false}] = AppUpdates.view("acme-intake").machines
    end

    test "the updater is told whether the installer must be signed", %{build01: b} do
      {:ok, 1} = AppUpdates.approve("acme-intake", b.id)

      assert [%{require_signature: true, signer: "Example Software Ltd"}] =
               AppUpdates.ask(b.id, %{})

      {:ok, _} = AppUpdates.save("acme-intake", %{"require_signature" => false, "signer" => ""})
      assert [%{require_signature: false, signer: ""}] = AppUpdates.ask(b.id, %{})
    end

    test "an install that started is not replaced, and a hold stops one not yet picked up", %{
      build01: b
    } do
      {:ok, 1} = AppUpdates.approve("acme-intake", b.id)
      assert [_] = AppUpdates.ask(b.id, %{})

      assert {:error, "not_eligible", "build01 is installing v1.4.0 of acme-intake now" <> _} =
               AppUpdates.approve("acme-intake", b.id)

      assert {:ok, 0} = AppUpdates.approve("acme-intake", :all)

      :ok =
        AppUpdates.result(b.id, %{
          "service" => "acme-intake",
          "version" => "v1.4.0",
          "ok" => false
        })

      {:ok, 1} = AppUpdates.approve("acme-intake", b.id)
      {:ok, _} = AppUpdates.save("acme-intake", %{"hold" => true})
      assert target(b).wanted_version == nil
      assert AppUpdates.ask(b.id, %{}) == []
    end

    test "a held app's queued job is not handed out", %{build01: b} do
      {:ok, 1} = AppUpdates.approve("acme-intake", b.id)
      [_] = AppUpdates.ask(b.id, %{})
      {:ok, _} = AppUpdates.save("acme-intake", %{"hold" => true})
      assert target(b).wanted_version == "v1.4.0"
      assert AppUpdates.ask(b.id, %{}) == []
    end

    test "another repository's releases are not reused" do
      assert AppUpdates.newest("acme-intake")
      {:ok, _} = AppUpdates.save("acme-intake", %{"repo" => "example/other"})
      assert AppUpdates.newest("acme-intake") == nil
      refute File.exists?(AppUpdates.dir("acme-intake", "v1.4.0"))
    end

    test "a check of the same name from the file is never touched by update results", %{
      build01: b
    } do
      service = Repo.get_by!(Service, machine_id: b.id, slug: "acme-intake")

      own =
        Repo.insert!(%Check{
          service_id: service.id,
          name: "dokkit.app-update",
          type: :tcp,
          source: :file,
          config: %{"port" => 8443}
        })

      {:ok, 1} = AppUpdates.approve("acme-intake", b.id)

      :ok =
        AppUpdates.result(b.id, %{
          "service" => "acme-intake",
          "version" => "v1.4.0",
          "ok" => false
        })

      assert Repo.reload!(own).state == :unknown
      assert Repo.all(from i in Issue, where: is_nil(i.closed_at)) == []
    end

    test "a failed install opens an issue, and the next good one closes it", %{build01: b} do
      {:ok, 1} = AppUpdates.approve("acme-intake", b.id)

      :ok =
        AppUpdates.result(b.id, %{
          "service" => "acme-intake",
          "version" => "v1.4.0",
          "ok" => false,
          "note" => "checks did not pass within 5m; the previous version was put back"
        })

      assert [%Issue{title: "Acme intake did not update to v1.4.0", state: :down}] =
               Repo.all(from i in Issue, where: is_nil(i.closed_at))

      assert Repo.all(Deploy) == []
      {:ok, 1} = AppUpdates.approve("acme-intake", b.id)

      :ok =
        AppUpdates.result(b.id, %{"service" => "acme-intake", "version" => "v1.4.0", "ok" => true})

      assert Repo.all(from i in Issue, where: is_nil(i.closed_at)) == []
      assert %Check{state: :ok} = Repo.get_by(Check, name: "dokkit.app-update")
    end

    test "an install that never reports back counts as failed", %{build01: b} do
      {:ok, 1} = AppUpdates.approve("acme-intake", b.id)
      AppUpdates.expire(DateTime.add(DateTime.utc_now(), 3 * 3600))

      assert %{ok: false, wanted_version: nil, note: "did not report back within 50 minutes"} =
               target(b)
    end
  end

  test "automatic mode goes one machine at a time and stops at the first failure", %{build01: b} do
    others = for name <- ~w(build02 build03), do: machine(name)
    for m <- [b | others], do: declare(m)
    configure(%{"mode" => "automatic"})
    github(self())

    {:ok, _} = AppUpdates.fetch("acme-intake")
    wanted = fn -> for m <- [b | others], do: target(m).wanted_version end
    assert wanted.() == ["v1.4.0", nil, nil]

    :ok =
      AppUpdates.result(b.id, %{"service" => "acme-intake", "version" => "v1.4.0", "ok" => true})

    assert wanted.() == [nil, "v1.4.0", nil]

    [b2, b3] = others

    :ok =
      AppUpdates.result(b2.id, %{"service" => "acme-intake", "version" => "v1.4.0", "ok" => false})

    assert wanted.() == [nil, nil, nil]
    assert AppUpdates.advance("acme-intake") == :stopped
    assert AppUpdates.tick() != :aborted
    assert target(b3).wanted_version == nil

    assert [%Issue{title: "Acme intake did not update to v1.4.0; automatic updates stopped"}] =
             Repo.all(from i in Issue, where: is_nil(i.closed_at))
  end

  test "the MCP shows an app's updates, changes them and refuses a host that only logs", %{
    build01: b,
    admin: admin
  } do
    declare(b)
    configure()
    github(self())
    host = Repo.insert!(%Machine{name: "laptop7", kind: :seen, last_seen_at: DateTime.utc_now()})

    tool = fn name, args ->
      build_conn()
      |> put_req_header("authorization", "Bearer " <> admin)
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: args}
      })
      |> json_response(200)
      |> get_in(["result", "content"])
      |> List.last()
      |> Map.fetch!("text")
    end

    assert tool.("fetch_app_releases", %{app: "acme-intake"}) =~ "v1.4.0"

    assert tool.("set_app_update", %{app: "acme-intake", signer: "Example Software Ltd"}) =~
             "Example Software Ltd"

    assert tool.("app_update", %{app: "acme-intake"}) =~ "build01"

    assert tool.("update_app", %{app: "acme-intake", machine: host.id}) =~
             "not a monitored machine"

    assert tool.("update_app", %{app: "acme-intake", machine: b.id}) =~ "\"machines\":1"
    assert tool.("github_token", %{}) =~ "not set"
  end

  test "the service page and Everything show the app's updates, and an owner updates from them",
       %{conn: conn, build01: b} do
    service = declare(b)
    configure()
    github(self())
    {:ok, _} = AppUpdates.fetch("acme-intake")

    {:ok, view, html} = live(signed_in(conn), ~p"/s/#{service.id}")
    assert html =~ "example/acme-intake"
    assert html =~ "v1.4.0"
    assert html =~ "Update to v1.4.0"

    view |> element("#app-machine-#{b.id} button", "Update to v1.4.0") |> render_click()
    assert target(b).wanted_version == "v1.4.0"
    assert render(view) =~ "Asked to move to v1.4.0"

    html = view |> form("#app-update-form", app: %{repo: "not a repo"}) |> render_submit()
    assert html =~ "repo is a GitHub repository, owner/name."

    html = view |> form("#app-update-form", app: %{mode: "automatic"}) |> render_submit()
    assert html =~ "Reset"
    assert AppUpdates.settings("acme-intake")["mode"] == "automatic"
    view |> element("button[phx-value-field=mode]", "Reset") |> render_click()
    assert AppUpdates.settings("acme-intake")["mode"] == "click"

    :ok =
      AppUpdates.result(b.id, %{"service" => "acme-intake", "version" => "v1.4.0", "ok" => false})

    {:ok, viewer_view, _} = live(viewer(build_conn()), ~p"/s/#{service.id}")
    refute has_element?(viewer_view, "#app-machine-#{b.id} button")
    render_click(viewer_view, "app_update_all", %{})
    assert target(b).wanted_version == nil

    {:ok, everything, html} = live(signed_in(build_conn()), ~p"/all")
    assert html =~ "App updates"
    everything |> element("#app-update-acme-intake button") |> render_click()
    assert target(b).wanted_version == "v1.4.0"
  end
end
