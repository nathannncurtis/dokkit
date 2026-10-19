defmodule DokkitWeb.NamesTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Dokkit.{Acme, Certificate, FakeAcme, Names, Setting, TestCerts}

  @name "home.dokkit.dev"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "dokkit-names-test-#{Base.encode16(:crypto.strong_rand_bytes(6))}"
      )

    installed = TestCerts.self_signed(["server.test"], dir)
    keys = [:tls, :cert, :acme_wait, :acme_authoritative, :acme_poll, :names_service]
    old = Application.get_all_env(:dokkit)
    Application.put_env(:dokkit, :tls, Path.join(dir, "tls"))
    Application.put_env(:dokkit, :cert, installed.path)
    Application.put_env(:dokkit, :acme_wait, {0, 3})
    Application.put_env(:dokkit, :acme_authoritative, false)
    Application.put_env(:dokkit, :acme_poll, {0, 5})
    Application.put_env(:dokkit, :names_service, "https://names.test")
    Certificate.load()
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.Test.set_req_test_to_private(%{})
      for k <- keys, do: Application.put_env(:dokkit, k, old[k])
      :persistent_term.erase({Certificate, :uploaded})
    end)

    :ok
  end

  defp calls(acc \\ []) do
    receive do
      {:call, what} -> calls([what | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp claimed do
    FakeAcme.start(self())
    {:ok, _} = Acme.save(%{"acme_directory" => FakeAcme.directory()})

    assert {:ok, "home.dokkit.dev now points at this server."} =
             Names.claim("goodcode1", "192.168.1.20")
  end

  test "a claim registers this server's key and sends the address" do
    claimed()

    key =
      Certificate.dir()
      |> Path.join("dokkit-name.pem")
      |> File.read!()
      |> :public_key.pem_decode()
      |> hd()
      |> :public_key.pem_entry_decode()

    assert [{:names_register, jwk}, {:names_address, "192.168.1.20"}] = calls()
    assert jwk == Acme.jwk(key)
    assert Names.name() == @name
    assert Acme.view()["acme_name"] == @name

    assert %{"name" => @name, "ok" => true, "note" => "home.dokkit.dev points at 192.168.1.20"} =
             Names.view()
  end

  test "a wrong code or a bad address saves nothing" do
    FakeAcme.start(self())

    assert {:error, "The claim service refused: That claim code is not known" <> _} =
             Names.claim("wrongcode1", "")

    assert {:error, "The address is an IPv4 address" <> _} = Names.claim("goodcode1", "10.0.0")
    assert {:error, "Paste the claim code" <> _} = Names.claim("", "")
    assert Names.name() == nil
    refute File.exists?(Path.join(Certificate.dir(), "dokkit-name.pem"))
  end

  test "the certificate is proved through the claim service, not Cloudflare" do
    claimed()
    calls()

    assert {:ok, "Renewed, runs out " <> _} = Acme.renew()
    assert %{names: [@name], self_signed: false} = Certificate.view().uploaded

    calls = calls()
    refute Enum.any?(calls, &match?({:zone, _}, &1))
    [{:names_txt, value}] = Enum.filter(calls, &match?({:names_txt, _}, &1))

    account =
      Certificate.dir()
      |> Path.join("acme-account.pem")
      |> File.read!()
      |> :public_key.pem_decode()
      |> hd()
      |> :public_key.pem_entry_decode()

    assert value ==
             Acme.txt_value("evaGxfADs6pSRb2LAv9IZf17Dt3juxGJ-PCt92wr-oA", Acme.jwk(account))

    assert Enum.find_index(calls, &(&1 == :names_txt_cleared)) >
             Enum.find_index(calls, &match?({:names_txt, _}, &1))
  end

  test "the address is sent daily, at once when it changes, and an hour after a failure" do
    claimed()
    calls()
    {:ok, at, _} = DateTime.from_iso8601(Names.settings()["at"])

    Names.tick(DateTime.add(at, 23 * 3600))
    assert calls() == []

    Acme.tick(DateTime.add(at, 24 * 3600))
    assert {:names_address, "192.168.1.20"} in calls()

    Setting.put("dokkit_name", Map.put(Names.settings(), "address", "192.168.1.21"))
    Names.tick(DateTime.add(at, 24 * 3600 + 60))
    assert calls() == [{:names_address, "192.168.1.21"}]

    File.rm!(Path.join(Certificate.dir(), "dokkit-name.pem"))
    Setting.put("dokkit_name", Map.put(Names.settings(), "address", "192.168.1.22"))
    later = DateTime.add(at, 24 * 3600 + 120)
    Names.tick(later)
    assert %{"ok" => false, "note" => "This server holds no key" <> _} = Names.view()
    Setting.put("dokkit_name", Map.put(Names.settings(), "address", "192.168.1.23"))
    Names.tick(DateTime.add(later, 1800))
    assert Names.settings()["at"] == DateTime.to_iso8601(later)
  end

  test "this machine's own address is an IPv4 address when it has one" do
    case Names.own_address() do
      nil -> :ok
      ip -> assert {:ok, {_, _, _, _}} = :inet.parse_ipv4strict_address(String.to_charlist(ip))
    end
  end

  test "the owner pastes the code in Settings and a certificate follows", %{conn: conn} do
    FakeAcme.start(self())
    {:ok, _} = Acme.save(%{"acme_directory" => FakeAcme.directory()})
    {:ok, view, html} = live(signed_in(conn), "/settings")
    assert html =~ "Claim code"

    html =
      view
      |> form("#name-form-0", claim: %{code: "goodcode1", address: "192.168.1.20"})
      |> render_submit()

    assert html =~ "home.dokkit.dev now points at this server."
    assert html =~ "This server holds <b>home.dokkit.dev</b>"
    assert wait_for(view, "Renewed, runs out") =~ @name
  end

  test "the API claims and shows the name, for admin only", %{conn: conn} do
    FakeAcme.start(self())
    {read, _} = Dokkit.Keys.mint(:user, %{scopes: ["read"]})
    {admin, _} = Dokkit.Keys.mint(:user, %{scopes: ["admin", "read-logs"]})

    call = fn method, token, body ->
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer " <> token)
      |> dispatch(@endpoint, method, "/api/v1/certificate/name", body)
    end

    assert json_response(call.(:get, read, %{}), 403)
    assert json_response(call.(:post, read, %{code: "goodcode1"}), 403)
    assert %{"name" => ""} = json_response(call.(:get, admin, %{}), 200)

    assert %{"error" => %{"code" => "bad_claim"}} =
             json_response(call.(:post, admin, %{code: "wrongcode1"}), 422)

    assert %{"name" => @name, "address" => "192.168.1.20", "ok" => true} =
             json_response(
               call.(:post, admin, %{code: "goodcode1", address: "192.168.1.20"}),
               200
             )

    assert %{"name" => @name} = json_response(call.(:get, admin, %{}), 200)
  end

  defp wait_for(view, text, tries \\ 100) do
    html = render(view)

    cond do
      html =~ text -> html
      tries == 0 -> flunk("never showed #{text}")
      true -> Process.sleep(50) && wait_for(view, text, tries - 1)
    end
  end
end
