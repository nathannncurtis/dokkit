defmodule DokkitWeb.UpdatesTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias Dokkit.{Keys, Machine, Releases, Repo, User}

  setup do
    dir = Path.join(System.tmp_dir!(), "dokkit-rel-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    old = Application.get_env(:dokkit, :releases)
    Application.put_env(:dokkit, :releases, dir)

    on_exit(fn ->
      Application.put_env(:dokkit, :releases, old)
      Application.delete_env(:dokkit, :release_max)
    end)

    machine = Repo.insert!(%Machine{name: "vault", kind: :enrolled, os: "windows"})
    {mkey, _} = Keys.mint(:machine, %{machine_id: machine.id})
    {read, _} = Keys.mint(:user, %{scopes: ["read"]})
    {act, _} = Keys.mint(:user, %{scopes: ["read", "act"]})
    {admin, _} = Keys.mint(:user, %{scopes: ["admin"]})
    %{dir: dir, machine: machine, mkey: mkey, read: read, act: act, admin: admin}
  end

  defp call(method, path, token, body \\ "") do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header(
      "content-type",
      if(is_binary(body), do: "application/octet-stream", else: "application/json")
    )
    |> dispatch(@endpoint, method, "/api/v1" <> path, body)
  end

  defp put_file(token, version, file, body \\ "x"),
    do: call(:put, "/releases/#{version}/#{file}", token, body)

  defp hold(admin, version) do
    for f <- ["SHA256SUMS", "SHA256SUMS.sig"],
        do: assert(json_response(put_file(admin, version, f, "v"), 200))
  end

  defp reload(machine), do: Repo.get!(Machine, machine.id)

  describe "storing releases" do
    test "upload, list, download and delete", %{admin: admin, read: read, mkey: mkey, dir: dir} do
      assert %{"ok" => true} = json_response(put_file(admin, "v1.0.0", "SHA256SUMS", "sums"), 200)
      assert File.read!(Path.join([dir, "v1.0.0", "SHA256SUMS"])) == "sums"

      assert %{"ok" => true} =
               json_response(put_file(admin, "v1.0.0", "SHA256SUMS", "again"), 200)

      assert %{
               "items" => [
                 %{"version" => "v1.0.0", "files" => ["SHA256SUMS"], "complete" => false}
               ]
             } =
               json_response(call(:get, "/releases", read), 200)

      hold(admin, "v1.0.0")

      assert %{"items" => [%{"files" => ["SHA256SUMS", "SHA256SUMS.sig"], "complete" => true}]} =
               json_response(call(:get, "/releases", read), 200)

      assert response(call(:get, "/releases/v1.0.0/SHA256SUMS", mkey), 200) == "v"
      assert json_response(call(:get, "/releases/v1.0.0/nope", mkey), 404)

      assert json_response(call(:delete, "/releases/v1.0.0", admin), 200)
      assert %{"items" => []} = json_response(call(:get, "/releases", read), 200)
      assert json_response(call(:delete, "/releases/v1.0.0", admin), 404)
    end

    test "a large body is written in chunks, and one over the limit is refused", %{
      admin: admin,
      mkey: mkey,
      dir: dir
    } do
      big = :binary.copy("0123456789abcdef", 1_500_000)
      assert json_response(put_file(admin, "v1.0.0", "dokkit-windows-x64.zip", big), 200)

      assert File.stat!(Path.join([dir, "v1.0.0", "dokkit-windows-x64.zip"])).size ==
               byte_size(big)

      assert response(call(:get, "/releases/v1.0.0/dokkit-windows-x64.zip", mkey), 200) == big

      Application.put_env(:dokkit, :release_max, 1_000_000)

      assert %{"error" => %{"code" => "too_large"}} =
               json_response(put_file(admin, "v1.0.1", "f", big), 413)

      refute File.exists?(Path.join([dir, "v1.0.1", "f"]))
      assert File.ls!(Path.join(dir, ".incoming")) == []
    end

    test "names are checked and a path cannot leave the folder", %{
      admin: admin,
      mkey: mkey,
      dir: dir
    } do
      for {v, f} <- [
            {"v1 0", "a"},
            {"v1.0.0", "a b"},
            {"v1.0.0", "a%2F..%2Fb"},
            {"..", "x"},
            {"v1.0.0", ".."},
            {"v1.0.0", ".hidden"}
          ] do
        assert %{"error" => %{"code" => "bad_name"}} = json_response(put_file(admin, v, f), 422)
      end

      assert json_response(call(:get, "/releases/..%2F..%2Fsettings.env/x", mkey), 404)
      assert json_response(call(:get, "/releases/v1.0.0/..%2F..%2Fx", mkey), 404)
      assert json_response(call(:delete, "/releases/..", admin), 422)
      refute File.exists?(dir)
    end

    test "each call refuses the wrong key or scope", %{
      admin: admin,
      read: read,
      act: act,
      mkey: mkey
    } do
      hold(admin, "v1.0.0")

      for token <- [read, act, mkey] do
        assert response(put_file(token, "v1.0.1", "f"), (token == mkey && 401) || 403)
        assert response(call(:delete, "/releases/v1.0.0", token), (token == mkey && 401) || 403)
      end

      assert response(call(:get, "/releases", mkey), 401)
      assert response(call(:get, "/releases/v1.0.0/SHA256SUMS", read), 401)
      assert response(call(:get, "/releases/v1.0.0/SHA256SUMS", admin), 401)
      assert response(call(:get, "/releases", "nope"), 401)
      assert Releases.complete?("v1.0.0")
    end
  end

  describe "what the updater asks" do
    defp ask(mkey, params \\ %{}) do
      query =
        URI.encode_query(
          Map.merge(
            %{"program" => "v1.0.0", "updater" => "v1.0.0", "os" => "windows", "arch" => "x64"},
            params
          )
        )

      call(:get, "/update?" <> query, mkey)
    end

    test "nothing wanted answers 204 and the machine is remembered", %{mkey: mkey, machine: m} do
      assert response(ask(mkey), 204) == ""
      m = reload(m)

      assert %{
               has_updater: true,
               hosts_server: false,
               program_version: "v1.0.0",
               updater_version: "v1.0.0"
             } = m

      assert response(ask(mkey, %{"server" => "v0.9.0"}), 204)
      assert %{hosts_server: true, server_version: "v0.9.0"} = reload(m)
    end

    test "a wanted version the server does not hold completely is not offered", %{
      mkey: mkey,
      machine: m,
      admin: admin
    } do
      Repo.update_all(Machine, set: [wanted_version: "v1.1.0"])
      assert response(ask(mkey), 204)
      put_file(admin, "v1.1.0", "SHA256SUMS")
      assert response(ask(mkey), 204)
      hold(admin, "v1.1.0")
      assert %{"version" => "v1.1.0"} = json_response(ask(mkey), 200)
      assert reload(m).wanted_version == "v1.1.0"
    end

    test "already on the wanted version, or only one part behind", %{mkey: mkey, admin: admin} do
      hold(admin, "v1.1.0")
      Repo.update_all(Machine, set: [wanted_version: "v1.1.0"])
      assert response(ask(mkey, %{"program" => "v1.1.0", "updater" => "v1.1.0"}), 204)
      assert %{"version" => "v1.1.0"} = json_response(ask(mkey, %{"program" => "v1.1.0"}), 200)
      assert %{"version" => "v1.1.0"} = json_response(ask(mkey, %{"updater" => "v1.1.0"}), 200)
    end

    test "a machine that hosts the server is behind when the server is", %{
      mkey: mkey,
      admin: admin
    } do
      hold(admin, "v1.1.0")
      Repo.update_all(Machine, set: [wanted_version: "v1.1.0"])
      same = %{"program" => "v1.1.0", "updater" => "v1.1.0"}
      assert response(ask(mkey, same), 204)

      assert %{"version" => "v1.1.0"} =
               json_response(ask(mkey, Map.put(same, "server", "v1.0.0")), 200)

      assert response(ask(mkey, Map.put(same, "server", "v1.1.0")), 204)
    end

    test "a result that worked clears the wanted version; one that failed keeps it", %{
      mkey: mkey,
      machine: m
    } do
      Repo.update_all(Machine, set: [wanted_version: "v1.1.0"])

      bad = %{version: "v1.1.0", ok: false, note: "service did not start"}
      assert json_response(call(:post, "/update/result", mkey, bad), 200)

      assert %{wanted_version: "v1.1.0", update_ok: false, update_note: "service did not start"} =
               reload(m)

      assert json_response(
               call(:post, "/update/result", mkey, %{version: "v1.1.0", ok: true, note: "program"}),
               200
             )

      assert %{wanted_version: nil, update_ok: true, update_version: "v1.1.0"} = reload(m)

      for body <- [
            %{version: "v1.1.0"},
            %{ok: true},
            %{version: "v1", ok: true, note: String.duplicate("x", 2001)}
          ] do
        assert json_response(call(:post, "/update/result", mkey, body), 422)
      end
    end

    test "only a machine key asks", %{admin: admin} do
      assert response(call(:get, "/update", admin), 401)
      assert response(call(:post, "/update/result", admin, %{version: "v1.0.0", ok: true}), 401)
    end
  end

  describe "approving" do
    test "one machine, all machines, and versions that cannot be approved", %{
      machine: m,
      admin: admin,
      act: act,
      read: read
    } do
      other = Repo.insert!(%Machine{name: "other", kind: :enrolled})
      Repo.update_all(from(x in Machine, where: x.id == ^m.id), set: [has_updater: true])
      hold(admin, "v1.1.0")
      put_file(admin, "v1.2.0", "SHA256SUMS")

      assert %{"error" => %{"code" => "not_held"}} =
               json_response(
                 call(:post, "/machines/#{m.id}/update", admin, %{version: "v1.2.0"}),
                 422
               )

      assert %{"error" => %{"code" => "not_held"}} =
               json_response(
                 call(:post, "/machines/#{m.id}/update", admin, %{version: "v9.9.9"}),
                 422
               )

      assert %{"error" => %{"code" => "bad_version"}} =
               json_response(
                 call(:post, "/machines/#{m.id}/update", admin, %{version: "latest"}),
                 422
               )

      assert %{"error" => %{"code" => "not_held"}} =
               json_response(call(:post, "/update-all", admin, %{version: "v1.2.0"}), 422)

      assert json_response(
               call(:post, "/machines/#{Ecto.UUID.generate()}/update", admin, %{version: "v1.1.0"}),
               404
             )

      assert reload(m).wanted_version == nil

      for token <- [act, read] do
        assert response(call(:post, "/machines/#{m.id}/update", token, %{version: "v1.1.0"}), 403)
        assert response(call(:post, "/update-all", token, %{version: "v1.1.0"}), 403)
      end

      assert %{"ok" => true, "version" => "v1.1.0"} =
               json_response(
                 call(:post, "/machines/#{other.id}/update", admin, %{version: "v1.1.0"}),
                 200
               )

      assert reload(other).wanted_version == "v1.1.0"
      assert reload(m).wanted_version == nil

      assert %{"machines" => 1} =
               json_response(call(:post, "/update-all", admin, %{version: "v1.1.0"}), 200)

      assert reload(m).wanted_version == "v1.1.0"
    end

    test "without a version the older fetch still answers", %{machine: m, admin: admin} do
      assert %{"error" => %{"code" => "no_program"}} =
               json_response(call(:post, "/machines/#{m.id}/update", admin, %{}), 422)
    end

    test "the tools list releases and approve", %{admin: admin, machine: m, read: read} do
      hold(admin, "v1.1.0")
      Repo.update_all(Machine, set: [has_updater: true])

      rpc = fn token, name, args ->
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/mcp", %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: name, arguments: args}
        })
        |> json_response(200)
      end

      assert %{"result" => %{"content" => [_, %{"text" => text}]}} = rpc.(read, "releases", %{})
      assert text =~ "v1.1.0"

      assert %{"result" => %{"isError" => true}} =
               rpc.(read, "update_all", %{"version" => "v1.1.0"})

      assert %{"result" => %{"content" => [_, %{"text" => ok}]}} =
               rpc.(admin, "update_machine", %{"id" => m.id, "version" => "v1.1.0"})

      assert ok =~ "v1.1.0"
      assert reload(m).wanted_version == "v1.1.0"

      assert %{"result" => %{"isError" => true}} =
               rpc.(admin, "update_all", %{"version" => "v7.0.0"})

      tools = fn token ->
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/mcp", %{jsonrpc: "2.0", id: 1, method: "tools/list"})
        |> json_response(200)
        |> get_in(["result", "tools"])
        |> Map.new(&{&1["name"], &1["annotations"]})
      end

      assert tools.(admin)["update_all"] == %{"readOnlyHint" => false, "destructiveHint" => true}
      assert tools.(read)["releases"] == %{"readOnlyHint" => true}
      refute Map.has_key?(tools.(read), "update_machine")
    end
  end

  describe "versions" do
    test "v and three numbers; anything else is older than every real version" do
      assert Releases.newer?("v1.10.0", "v1.9.9")
      assert Releases.newer?("v1.0.0", "1.0")
      assert Releases.newer?("v0.0.0", nil)
      refute Releases.newer?("dev", "v0.0.1")
      refute Releases.newer?("v1.0.0", "v1.0.0")
    end
  end

  describe "the machine list" do
    defp member(conn) do
      user = Repo.insert!(%User{name: "mia", password_hash: "-", role: :member})

      Plug.Test.init_test_session(conn, %{
        "user_id" => user.id,
        "signed_at" => Dokkit.Accounts.stamp()
      })
    end

    defp settled(view) do
      send(view.pid, {:settled, :page})
      render(view)
    end

    defp with_updater(m, attrs \\ []),
      do:
        Repo.update_all(from(x in Machine, where: x.id == ^m.id),
          set: Keyword.merge([has_updater: true, program_version: "v1.0.0"], attrs)
        )

    test "the owner gets a button; a member does not; each state is told", %{
      conn: conn,
      machine: m,
      admin: admin,
      mkey: mkey
    } do
      with_updater(m)
      {:ok, view, html} = live(signed_in(conn), "/all")
      refute html =~ "Update to"
      refute html =~ "dokkit updater install"
      assert html =~ "Program v1.0.0"

      hold(admin, "v1.1.0")
      {:ok, view2, html} = live(signed_in(conn), "/all")
      assert html =~ "Update to v1.1.0"
      refute html =~ "Update all"
      {:ok, _, member_html} = live(member(conn), "/all")
      refute member_html =~ "Update to"
      assert member_html =~ "Program v1.0.0"
      _ = view

      html = view2 |> element("#upd-#{m.id} button") |> render_click()
      assert html =~ "Asked to move to v1.1.0"
      refute html =~ "Update to v1.1.0"
      assert reload(m).wanted_version == "v1.1.0"

      json_response(
        call(:post, "/update/result", mkey, %{version: "v1.1.0", ok: false, note: "file in use"}),
        200
      )

      html = settled(view2)
      assert html =~ "Update to v1.1.0 failed: file in use"
      assert has_element?(view2, "#upd-#{m.id} button")

      json_response(
        call(:post, "/update/result", mkey, %{version: "v1.1.0", ok: true, note: "program"}),
        200
      )

      Repo.update_all(from(x in Machine, where: x.id == ^m.id), set: [program_version: "v1.1.0"])
      html = settled(view2)
      assert html =~ "Updated to v1.1.0"
      refute html =~ "failed"
    end

    test "Update all shows when more than one machine can move", %{
      conn: conn,
      machine: m,
      admin: admin
    } do
      other = Repo.insert!(%Machine{name: "other", kind: :enrolled})
      with_updater(m)
      with_updater(other)
      hold(admin, "v1.1.0")
      {:ok, view, html} = live(signed_in(conn), "/all")
      assert html =~ "Update all to v1.1.0"
      {:ok, _, member_html} = live(member(conn), "/all")
      refute member_html =~ "Update all"

      view |> element("#update-all") |> render_click()
      assert reload(m).wanted_version == "v1.1.0"
      assert reload(other).wanted_version == "v1.1.0"
      refute render(view) =~ "Update all"
    end

    test "a server host shows both versions and moves when the server is behind", %{
      conn: conn,
      machine: m,
      admin: admin
    } do
      with_updater(m, hosts_server: true, server_version: "v1.0.0", program_version: "v1.1.0")
      hold(admin, "v1.1.0")
      {:ok, _, html} = live(signed_in(conn), "/all")
      assert html =~ "Program v1.1.0 / Server v1.0.0"
      assert html =~ "Update to v1.1.0"
    end

    test "a Windows machine without an updater is told once how to get one", %{
      conn: conn,
      machine: m
    } do
      {:ok, _, html} = live(signed_in(conn), "/all")

      assert html =~ "No updater on this machine."
      assert html =~ "dokkit updater install"

      Repo.update_all(from(x in Machine, where: x.id == ^m.id), set: [os: "linux"])
      {:ok, _, html} = live(signed_in(conn), "/all")
      refute html =~ "updater"
    end

    test "Settings lists the releases for the owner only", %{conn: conn, admin: admin} do
      put_file(admin, "v1.0.0", "SHA256SUMS")
      hold(admin, "v1.1.0")
      {:ok, _, html} = live(signed_in(conn), "/settings")
      assert html =~ "release-v1.0.0"
      assert html =~ "Incomplete"
      assert html =~ "Complete"
      {:ok, _, html} = live(member(conn), "/settings")
      refute html =~ "Releases"
    end
  end
end
