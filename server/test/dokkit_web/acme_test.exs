defmodule DokkitWeb.AcmeTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Dokkit.{Acme, Certificate, Cloudflare, FakeAcme, Keys, Repo, Setting, TestCerts, User}

  @name "example.dokkit.dev"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "dokkit-acme-test-#{Base.encode16(:crypto.strong_rand_bytes(6))}"
      )

    installed = TestCerts.self_signed(["server.test"], dir)
    old = Application.get_all_env(:dokkit)
    Application.put_env(:dokkit, :tls, Path.join(dir, "tls"))
    Application.put_env(:dokkit, :cert, installed.path)
    Application.put_env(:dokkit, :acme_wait, {0, 3})
    Application.put_env(:dokkit, :acme_poll, {0, 5})
    Certificate.load()
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.Test.set_req_test_to_private(%{})
      for k <- [:tls, :cert, :acme_wait, :acme_poll], do: Application.put_env(:dokkit, k, old[k])
      :persistent_term.erase({Certificate, :uploaded})
    end)

    {read, _} = Keys.mint(:user, %{scopes: ["read"]})
    {admin, _} = Keys.mint(:user, %{scopes: ["admin"]})
    %{read: read, admin: admin}
  end

  defp configure(extra \\ %{}) do
    {:ok, _} =
      Acme.save(
        Map.merge(
          %{
            "acme_name" => @name,
            "acme_cloudflare_token" => "cf-secret",
            "acme_directory" => FakeAcme.directory()
          },
          extra
        )
      )
  end

  defp calls(acc \\ []) do
    receive do
      {:call, what} -> calls([what | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the signing" do
    test "the thumbprint is the one in RFC 7638 section 3.1" do
      jwk = %{
        "kty" => "RSA",
        "n" =>
          "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw",
        "e" => "AQAB"
      }

      assert Acme.thumbprint(jwk) == "NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs"
    end

    test "the TXT value is the hash of the token, a dot and the thumbprint" do
      jwk = %{
        "crv" => "P-256",
        "kty" => "EC",
        "x" => "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU",
        "y" => "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"
      }

      token = "evaGxfADs6pSRb2LAv9IZf17Dt3juxGJ-PCt92wr-oA"

      assert Acme.thumbprint(jwk) ==
               Base.url_encode64(
                 :crypto.hash(
                   :sha256,
                   ~s({"crv":"P-256","kty":"EC","x":"f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU","y":"x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"})
                 ),
                 padding: false
               )

      expected =
        Base.url_encode64(:crypto.hash(:sha256, token <> "." <> Acme.thumbprint(jwk)),
          padding: false
        )

      assert Acme.txt_value(token, jwk) == expected
      assert byte_size(expected) == 43
    end

    test "a signed request carries its url and nonce, and verifies with the key's public half" do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      jwk = Acme.jwk(key)

      body =
        Acme.jws(
          key,
          %{url: "https://acme.test/order", nonce: "n1", kid: "https://acme.test/acct/1"},
          %{a: 1}
        )

      %{"protected" => p, "payload" => payload, "signature" => sig} = Jason.decode!(body)

      assert %{"alg" => "ES256", "url" => "https://acme.test/order", "nonce" => "n1", "kid" => _} =
               p |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert payload |> Base.url_decode64!(padding: false) |> Jason.decode!() == %{"a" => 1}
      <<r::256, s::256>> = Base.url_decode64!(sig, padding: false)
      der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})

      point =
        <<4>> <>
          Base.url_decode64!(jwk["x"], padding: false) <>
          Base.url_decode64!(jwk["y"], padding: false)

      assert :public_key.verify(
               p <> "." <> payload,
               :sha256,
               der,
               {{:ECPoint, point}, {:namedCurve, :secp256r1}}
             )

      assert %{"payload" => ""} = Jason.decode!(Acme.jws(key, %{url: "u", nonce: "n"}, ""))
    end

    test "the request for a certificate is well formed and names the name" do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      csr = Acme.csr(key, @name)
      assert {:CertificationRequest, _, _, _} = :public_key.der_decode(:CertificationRequest, csr)
      assert :binary.match(csr, @name) != :nomatch
    end
  end

  describe "Cloudflare" do
    test "the zone is looked for from the longest name to the shortest" do
      assert Cloudflare.candidates("a.b.dokkit.dev") == [
               "a.b.dokkit.dev",
               "b.dokkit.dev",
               "dokkit.dev"
             ]

      assert Cloudflare.candidates("dokkit.dev") == ["dokkit.dev"]
    end
  end

  describe "getting a certificate" do
    test "obtains it, serves it at once, and removes the record" do
      configure()
      fake = FakeAcme.start(self())
      now = DateTime.utc_now()

      assert {:ok, "Renewed, runs out " <> date} = Acme.renew(now)
      assert date == Date.utc_today() |> Date.add(90) |> Date.to_iso8601()

      assert %{names: [@name], self_signed: false} = Certificate.view().uploaded
      assert [certs_keys: [%{cert: [_leaf, _root]}]] = Certificate.sni(String.to_charlist(@name))

      calls = calls()
      assert {:zone, "example.dokkit.dev"} in calls

      assert Enum.find_index(calls, &(&1 == {:zone, "example.dokkit.dev"})) <
               Enum.find_index(calls, &(&1 == {:zone, "dokkit.dev"}))

      [{:txt_created, "_acme-challenge." <> @name, value, 60}] =
        Enum.filter(calls, &match?({:txt_created, _, _, _}, &1))

      assert value ==
               Acme.txt_value("evaGxfADs6pSRb2LAv9IZf17Dt3juxGJ-PCt92wr-oA", jwk_from_calls(fake))

      assert :txt_deleted in calls

      assert Enum.find_index(calls, &(&1 == :txt_deleted)) >
               Enum.find_index(calls, &match?({:txt_created, _, _, _}, &1))

      assert %{ok: true, note: "Renewed, runs out " <> _} = Certificate.view().renewal
      assert File.exists?(Path.join(Certificate.dir(), "acme-account.pem"))

      first = File.read!(Path.join(Certificate.dir(), "acme-account.pem"))
      FakeAcme.start(self())
      assert {:ok, _} = Acme.renew(now)
      assert File.read!(Path.join(Certificate.dir(), "acme-account.pem")) == first
    end

    defp jwk_from_calls(_fake) do
      key =
        Certificate.dir()
        |> Path.join("acme-account.pem")
        |> File.read!()
        |> :public_key.pem_decode()
        |> hd()
        |> :public_key.pem_entry_decode()

      Acme.jwk(key)
    end

    test "a challenge the authority rejects is reported and the record is still removed" do
      configure()
      FakeAcme.start(self(), mode: :invalid)

      assert {:error,
              "The certificate authority did not accept the challenge: Incorrect TXT record" <> _} =
               Acme.renew()

      assert :txt_deleted in calls()
      assert Certificate.view().uploaded == nil

      assert %{ok: false, note: "The certificate authority did not accept" <> _} =
               Certificate.view().renewal
    end

    test "Cloudflare refusing is reported" do
      configure()
      FakeAcme.start(self(), mode: :cloudflare_refuses)
      assert {:error, "Cloudflare refused: Authentication error"} = Acme.renew()
      refute :txt_deleted in calls()
      assert Certificate.view().uploaded == nil
    end

    test "a record that never shows in DNS is reported and removed" do
      configure()
      FakeAcme.start(self(), mode: :never_visible)
      assert {:error, "The challenge record for " <> _} = Acme.renew()
      assert :txt_deleted in calls()
    end

    test "a stale nonce is retried once" do
      configure()
      FakeAcme.start(self(), mode: :bad_nonce_once)
      assert {:ok, _} = Acme.renew()
      assert Enum.count(calls(), &(&1 == {:post, "/acct"})) == 2
    end

    test "settings must be complete" do
      assert {:error, "Set acme_name and acme_cloudflare_token first."} = Acme.renew()
    end
  end

  describe "the daily check" do
    defp upload_for_name(days) do
      c = TestCerts.issued([@name], validity: TestCerts.validity(-1, days))
      {:ok, view} = Certificate.put(c.cert, c.key)
      {:ok, not_after, _} = DateTime.from_iso8601(view.uploaded.not_after)
      not_after
    end

    defp forget_checks, do: Repo.delete(Repo.get!(Setting, "certificate_renewal"))

    test "does nothing at 31 days left, renews at 30" do
      configure()
      FakeAcme.start(self())
      not_after = upload_for_name(100)

      Acme.tick(DateTime.add(not_after, -31 * 86_400))
      assert calls() == []
      assert Certificate.view().renewal == nil

      forget_checks()
      Acme.tick(DateTime.add(not_after, -30 * 86_400))
      assert {:post, "/acct"} in calls()
      assert %{ok: true} = Certificate.view().renewal
    end

    test "renews when there is no certificate for the name" do
      configure()
      FakeAcme.start(self())
      Acme.tick(DateTime.utc_now())
      assert %{names: [@name]} = Certificate.view().uploaded
    end

    test "checks once a day, and after a failure tries again no sooner than twelve hours" do
      configure()
      FakeAcme.start(self(), mode: :invalid)
      not_after = upload_for_name(100)
      start = DateTime.add(not_after, -29 * 86_400)

      Acme.tick(start)
      assert {:post, "/acct"} in calls()
      assert %{ok: false} = Certificate.view().renewal

      Acme.tick(DateTime.add(start, 3600))
      assert calls() == []

      Acme.tick(DateTime.add(start, 11 * 3600))
      assert calls() == []

      Acme.tick(DateTime.add(start, 13 * 3600))
      assert {:post, "/acct"} in calls()
    end

    test "does nothing without settings" do
      Acme.tick(DateTime.utc_now())
      assert calls() == []
    end
  end

  describe "Dokkit's own certificate check" do
    test "carries the failure of the last renewal as its note" do
      configure()
      FakeAcme.start(self(), mode: :invalid)
      upload_for_name(100)
      assert {:error, _} = Acme.renew()
      Dokkit.Self.tick(DateTime.utc_now(), %{})

      %{check: check} =
        Enum.find(Dokkit.Issues.open_list(), &(&1.check.name == "certificate")) || %{check: nil}

      assert check == nil

      Dokkit.Self.tick(DateTime.add(DateTime.utc_now(), 90 * 86_400), %{})
      issue = Enum.find(Dokkit.Issues.open_list(), &(&1.check.name == "certificate"))
      assert issue.check.note =~ "runs out in"
      assert issue.check.note =~ "did not accept the challenge"
    end
  end

  describe "the API" do
    defp call(method, path, token, body \\ %{}) do
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> dispatch(@endpoint, method, "/api/v1" <> path, body)
    end

    test "settings are admin only, and the token is never returned", %{read: read, admin: admin} do
      assert json_response(call(:get, "/certificate/settings", read), 403)
      assert json_response(call(:put, "/certificate/settings", read, %{acme_name: @name}), 403)
      assert json_response(call(:post, "/certificate/renew", read), 403)

      assert %{
               "acme_name" => "",
               "acme_cloudflare_token" => "not set",
               "acme_directory" => "https://acme-v02.api.letsencrypt.org/directory"
             } =
               json_response(call(:get, "/certificate/settings", admin), 200)

      body =
        json_response(
          call(:put, "/certificate/settings", admin, %{
            acme_name: "Example.Dokkit.dev",
            acme_cloudflare_token: "cf-secret",
            acme_directory: FakeAcme.directory()
          }),
          200
        )

      assert body == %{
               "acme_name" => @name,
               "acme_cloudflare_token" => "set",
               "acme_directory" => FakeAcme.directory()
             }

      refute inspect(json_response(call(:get, "/certificate/settings", admin), 200)) =~
               "cf-secret"

      assert %{"acme_cloudflare_token" => "set", "acme_name" => "other.dokkit.dev"} =
               json_response(
                 call(:put, "/certificate/settings", admin, %{acme_name: "other.dokkit.dev"}),
                 200
               )

      assert %{"acme_cloudflare_token" => "not set"} =
               json_response(
                 call(:put, "/certificate/settings", admin, %{acme_cloudflare_token: ""}),
                 200
               )

      assert %{
               "error" => %{"code" => "bad_settings", "message" => "acme_name is a DNS name" <> _}
             } =
               json_response(
                 call(:put, "/certificate/settings", admin, %{acme_name: "*.dokkit.dev"}),
                 422
               )

      assert %{"error" => %{"message" => "acme_directory must be an https" <> _}} =
               json_response(
                 call(:put, "/certificate/settings", admin, %{acme_directory: "http://x.test/d"}),
                 422
               )
    end

    test "renew answers with the certificates, or the reason", %{admin: admin} do
      assert %{"error" => %{"code" => "renewal_failed", "message" => "Set acme_name" <> _}} =
               json_response(call(:post, "/certificate/renew", admin), 422)

      configure()
      FakeAcme.start(self())
      body = json_response(call(:post, "/certificate/renew", admin), 200)

      assert %{
               "uploaded" => %{"names" => [@name]},
               "renewal" => %{"ok" => true, "note" => "Renewed, runs out " <> _, "at" => _}
             } = body
    end
  end

  describe "the Settings card" do
    test "the owner saves the two fields there and asks for a certificate", %{conn: conn} do
      FakeAcme.start(self())
      {:ok, view, html} = live(signed_in(conn), "/settings")
      assert html =~ "Get a certificate now"
      assert html =~ "not set"

      html =
        view
        |> form("#acme-form-0",
          acme: %{
            acme_name: @name,
            acme_cloudflare_token: "cf-secret",
            acme_directory: FakeAcme.directory()
          }
        )
        |> render_submit()

      assert html =~ "Saved"
      refute html =~ "cf-secret"
      assert Acme.view()["acme_cloudflare_token"] == "set"

      html = view |> form("#acme-form-1", acme: %{acme_name: "*.bad"}) |> render_submit()
      assert html =~ "acme_name is a DNS name"
      assert Acme.view()["acme_name"] == @name

      assert render_click(view, "acme_now") =~ "Working"
      html = wait_for(view, "Renewed, runs out")
      assert html =~ @name
    end

    defp wait_for(view, text, tries \\ 100) do
      html = render(view)

      cond do
        html =~ text -> html
        tries == 0 -> flunk("never showed #{text}: " <> String.slice(html, 0, 300))
        true -> Process.sleep(50) && wait_for(view, text, tries - 1)
      end
    end

    test "the card shows a failure there", %{conn: conn} do
      configure()
      FakeAcme.start(self(), mode: :cloudflare_refuses)
      {:ok, view, _} = live(signed_in(conn), "/settings")
      render_click(view, "acme_now")
      assert wait_for(view, "Cloudflare refused: Authentication error") =~ "Get a certificate now"
    end

    test "a member sees none of it", %{conn: conn} do
      user = Repo.insert!(%User{name: "mia", password_hash: "-", role: :member})

      conn =
        Plug.Test.init_test_session(conn, %{
          "user_id" => user.id,
          "signed_at" => Dokkit.Accounts.stamp()
        })

      {:ok, view, html} = live(conn, "/settings")
      refute html =~ "Get a certificate now"
      assert render_click(view, "acme_now") =~ "Settings"
      assert Acme.view()["acme_name"] == ""
    end
  end
end
