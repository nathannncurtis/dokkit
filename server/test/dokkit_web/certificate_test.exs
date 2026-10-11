defmodule DokkitWeb.CertificateTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Dokkit.{Certificate, Issues, Keys, Repo, TestCerts, User}

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "dokkit-cert-test-#{Base.encode16(:crypto.strong_rand_bytes(6))}"
      )

    installed = TestCerts.self_signed(["server.test"], dir)
    old = Application.get_all_env(:dokkit)
    Application.put_env(:dokkit, :tls, Path.join(dir, "tls"))
    Application.put_env(:dokkit, :cert, installed.path)
    Certificate.load()

    on_exit(fn ->
      for k <- [:tls, :cert], do: Application.put_env(:dokkit, k, old[k])
      :persistent_term.erase({Certificate, :uploaded})
    end)

    {read, _} = Keys.mint(:user, %{scopes: ["read"]})
    {act, _} = Keys.mint(:user, %{scopes: ["read", "act"]})
    {admin, _} = Keys.mint(:user, %{scopes: ["admin"]})
    valid = TestCerts.validity(-1, 100)

    %{
      installed: installed,
      read: read,
      act: act,
      admin: admin,
      issued: TestCerts.issued(["a.example.test", "*.w.example.test"], validity: valid)
    }
  end

  defp call(method, token, body \\ %{}) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> dispatch(@endpoint, method, "/api/v1/certificate", body)
  end

  describe "refusals" do
    test "each says which check failed", %{issued: c} do
      assert Certificate.view().uploaded == nil, "at start"
      other = TestCerts.issued(["b.example.test"])
      old = TestCerts.issued(["old.example.test"], validity: TestCerts.validity(-10, -1))
      new = TestCerts.issued(["new.example.test"], validity: TestCerts.validity(5, 10))
      bare = TestCerts.issued([], validity: TestCerts.validity(-1, 10))

      cases = [
        {"nonsense", c.key, "No certificate could be read"},
        {c.cert, "nonsense", "No unencrypted private key"},
        {c.cert, other.key, "key does not belong"},
        {old.cert, old.key, "expired"},
        {new.cert, new.key, "not valid yet"},
        {bare.cert, bare.key, "no DNS name"}
      ]

      for {cert, key, text} <- cases do
        assert {:error, why} = Certificate.put(cert, key)
        assert why =~ text, "#{why} should say #{text}"
        assert Certificate.view().uploaded == nil, "after #{text}"
      end

      assert Certificate.view().uploaded == nil
    end

    test "a server without its own TLS refuses", %{issued: c} do
      Application.put_env(:dokkit, :cert, nil)

      assert {:error, "This server does not serve TLS itself" <> _} =
               Certificate.put(c.cert, c.key)

      assert {:error, _} = Certificate.delete()
    end
  end

  describe "the API" do
    test "upload, get and delete, with the scopes each needs", %{
      issued: c,
      read: read,
      act: act,
      admin: admin,
      installed: installed
    } do
      assert %{
               "installed" => %{"self_signed" => true, "names" => ["server.test"]},
               "uploaded" => nil
             } =
               json_response(call(:get, read), 200)

      assert json_response(call(:put, read, %{cert: c.cert, key: c.key}), 403)
      assert json_response(call(:put, act, %{cert: c.cert, key: c.key}), 403)
      assert json_response(call(:delete, read), 403)
      assert json_response(call(:get, admin), 403)

      body = json_response(call(:put, admin, %{cert: c.cert, key: c.key}), 200)
      refute inspect(body) =~ "PRIVATE"

      assert %{
               "names" => ["a.example.test", "*.w.example.test"],
               "self_signed" => false,
               "sha256" => sha,
               "issuer" => issuer,
               "not_after" => <<_::binary-4, "-", _::binary>>
             } = body["uploaded"]

      assert sha == TestCerts.fingerprint(c.der)
      assert issuer != ""
      assert body["installed"]["sha256"] == TestCerts.fingerprint(installed.der)
      assert json_response(call(:get, read), 200) == body

      assert %{"code" => "bad_certificate", "message" => "The key does not belong" <> _} =
               json_response(call(:put, admin, %{cert: c.cert, key: installed.key}), 422)["error"]

      assert %{"uploaded" => nil} = json_response(call(:delete, admin), 200)
      assert %{"uploaded" => nil} = json_response(call(:get, read), 200)
    end

    test "the files are saved beside the settings and survive a restart", %{
      issued: c,
      admin: admin
    } do
      call(:put, admin, %{cert: c.cert, key: c.key})
      assert File.read!(Path.join(Certificate.dir(), "cert.pem")) == c.cert
      :persistent_term.erase({Certificate, :uploaded})
      assert Certificate.view().uploaded == nil
      Certificate.load()
      assert %{names: ["a.example.test" | _]} = Certificate.view().uploaded
    end
  end

  describe "which certificate is served" do
    test "by the name asked for, with no restart", %{issued: c} do
      assert Certificate.sni(~c"a.example.test") == :undefined
      {:ok, _} = Certificate.put(c.cert, c.key)

      assert [certs_keys: [%{cert: chain}]] = Certificate.sni(~c"a.example.test")
      assert chain == c.chain
      assert [certs_keys: _] = Certificate.sni(~c"A.Example.Test")
      assert [certs_keys: _] = Certificate.sni(~c"x.w.example.test")
      assert Certificate.sni(~c"x.y.w.example.test") == :undefined
      assert Certificate.sni(~c"w.example.test") == :undefined
      assert Certificate.sni(~c"other.test") == :undefined
      assert Certificate.sni(:undefined) == :undefined

      {:ok, _} = Certificate.delete()
      assert Certificate.sni(~c"a.example.test") == :undefined
    end
  end

  describe "the server's names" do
    test "the configured host and every name of the certificate, in any case", %{issued: c} do
      host = String.downcase(DokkitWeb.Endpoint.host())
      refute Certificate.mine?("a.example.test")
      {:ok, _} = Certificate.put(c.cert, c.key)

      for name <- [host, "a.example.test", "A.EXAMPLE.TEST", "q.w.example.test"],
          do: assert(Certificate.mine?(name), name)

      refute Certificate.mine?("evil.test")
      assert Certificate.origin?(URI.parse("https://A.example.test"))
      assert Certificate.origin?(URI.parse("https://#{host}"))
      refute Certificate.origin?(URI.parse("https://evil.test"))
      refute Certificate.origin?(%URI{host: nil})
    end

    test "full control can be confirmed with either name", %{conn: conn, issued: c} do
      {:ok, _} = Certificate.put(c.cert, c.key)
      {:ok, view, _} = live(signed_in(conn), "/settings")
      render_click(view, "full")

      for name <- [DokkitWeb.Endpoint.host(), "a.example.test"] do
        f = %{"label" => "tool", "confirm" => name, "sure" => "true"}
        assert render_change(view, "full_typed", %{"full" => f}) =~ "Make a full-control token"

        refute render_change(view, "full_typed", %{"full" => f}) =~
                 ~r/class="btn danger"[^>]*disabled/
      end
    end

    test "the address shown is the certificate's first name once there is one", %{issued: c} do
      assert Certificate.address() == DokkitWeb.Endpoint.host()
      assert Certificate.url() == DokkitWeb.Endpoint.url()
      {:ok, _} = Certificate.put(c.cert, c.key)
      assert Certificate.address() == "a.example.test"
      assert Certificate.url() =~ "//a.example.test"
    end
  end

  describe "the enrol page" do
    defp command(conn) do
      {:ok, view, _} = live(signed_in(conn), "/machines/new")
      view |> element("button", "Make a token") |> render_click()
      render(view)
    end

    test "has the fingerprint, and has none once a trusted certificate covers the address", %{
      conn: conn,
      issued: c,
      installed: installed
    } do
      assert command(conn) =~ "sha256:" <> TestCerts.fingerprint(installed.der)
      {:ok, _} = Certificate.put(c.cert, c.key)
      html = command(conn)
      refute html =~ "sha256:"
      assert html =~ "//a.example.test"
    end

    test "keeps the fingerprint when the uploaded certificate is self-signed", %{conn: conn} do
      own = TestCerts.self_signed(["own.example.test"], Path.join(Certificate.dir(), "own"))
      {:ok, _} = Certificate.put(own.cert, own.key)
      assert command(conn) =~ "sha256:"
    end
  end

  describe "Dokkit's own certificate check" do
    defp certificate_issue do
      Enum.find(Issues.open_list(), &(&1.check.name == "certificate"))
    end

    test "is quiet at 60 days, soon at 21 and down at 0", %{issued: c} do
      {:ok, _} = Certificate.put(c.cert, c.key)
      now = DateTime.utc_now()

      Dokkit.Self.tick(DateTime.add(now, 40 * 86_400), %{})
      assert certificate_issue() == nil

      Dokkit.Self.tick(DateTime.add(now, 80 * 86_400), %{})
      assert %{state: :degraded, soon: true} = certificate_issue()

      Dokkit.Self.tick(DateTime.add(now, 101 * 86_400), %{})
      assert %{state: :down, soon: false} = certificate_issue()
    end

    test "is absent without an uploaded certificate" do
      Dokkit.Self.tick(DateTime.utc_now(), %{})
      assert Repo.get_by(Dokkit.Check, name: "certificate") == nil
    end
  end

  describe "the Settings card" do
    test "the owner sees it, saves a certificate there and sees the refusal there", %{
      conn: conn,
      issued: c
    } do
      {:ok, view, html} = live(signed_in(conn), "/settings")
      assert html =~ "Certificate"
      assert html =~ "server.test"
      assert html =~ "self-signed"

      html =
        view
        |> form("#certificate-form-0", certificate: %{cert: c.cert, key: "nonsense"})
        |> render_submit()

      assert html =~ "No unencrypted private key"

      html =
        view
        |> form("#certificate-form-1", certificate: %{cert: c.cert, key: c.key})
        |> render_submit()

      assert html =~ "Saved"
      assert html =~ "a.example.test"
      refute html =~ "PRIVATE KEY"
      assert %{names: ["a.example.test" | _]} = Certificate.view().uploaded

      html = render_click(view, "certificate_remove")
      assert html =~ "Removed"
      assert Certificate.view().uploaded == nil
    end

    test "a member does not see it", %{conn: conn} do
      user = Repo.insert!(%User{name: "mia", password_hash: "-", role: :member})

      conn =
        Plug.Test.init_test_session(conn, %{
          "user_id" => user.id,
          "signed_at" => Dokkit.Accounts.stamp()
        })

      {:ok, _view, html} = live(conn, "/settings")
      refute html =~ ~s(id="certificate")
    end
  end

  describe "a real listener" do
    test "serves the uploaded certificate for its name and the installed one otherwise", %{
      issued: c,
      installed: installed
    } do
      {:ok, _} = Certificate.put(c.cert, c.key)

      {:ok, listen} =
        :ssl.listen(0,
          certfile: String.to_charlist(installed.path),
          keyfile: String.to_charlist(Path.rootname(installed.path) <> "-key.pem"),
          sni_fun: &Certificate.sni/1,
          reuseaddr: true,
          active: false
        )

      {:ok, {_, port}} = :ssl.sockname(listen)
      acceptor = Task.async(fn -> accept(listen, 3) end)

      assert peer(port, ~c"a.example.test") == TestCerts.fingerprint(c.der)
      assert peer(port, ~c"x.w.example.test") == TestCerts.fingerprint(c.der)
      assert peer(port, :disable) == TestCerts.fingerprint(installed.der)

      Task.await(acceptor)

      {:ok, _} = Certificate.delete()
      acceptor = Task.async(fn -> accept(listen, 1) end)
      assert peer(port, ~c"a.example.test") == TestCerts.fingerprint(installed.der)
      Task.await(acceptor)
      :ssl.close(listen)
    end

    defp accept(listen, n) do
      for _ <- 1..n do
        {:ok, t} = :ssl.transport_accept(listen, 5000)
        {:ok, s} = :ssl.handshake(t, 5000)
        :ssl.close(s)
      end
    end

    defp peer(port, sni) do
      {:ok, s} =
        :ssl.connect(
          ~c"localhost",
          port,
          [verify: :verify_none, server_name_indication: sni, active: false],
          5000
        )

      {:ok, der} = :ssl.peercert(s)
      :ssl.close(s)
      TestCerts.fingerprint(der)
    end
  end
end
