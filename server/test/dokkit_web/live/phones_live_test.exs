defmodule DokkitWeb.PhonesLiveTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Dokkit.{Phones, Repo, User}

  @mailbox "92bea4d52a1d53f0c8111edf39e26a89"
  @upload_key "dkr_729nLrMYIgy8I0YoubM6pyvho0c71L4IJO9Y"
  @relay %{"address" => "https://relay.example.test", "mailbox" => @mailbox, "key" => @upload_key}

  setup do
    test = self()

    Req.Test.stub(Dokkit.Alerts, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:put, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"ok":true,"slots":{}}))
    end)

    :ok
  end

  test "the owner sets the relay, adds a phone, sees its code once, and removes it", %{conn: conn} do
    {:ok, view, html} = live(signed_in(conn), "/settings")
    assert html =~ "Phones"
    assert html =~ "Relay address"

    bad =
      view
      |> form("#relay-form", relay: %{@relay | "address" => "http://x.example.test"})
      |> render_submit()

    assert bad =~ "https://"

    html = view |> form("#relay-form", relay: @relay) |> render_submit()
    assert html =~ "The relay took the snapshot."
    assert html =~ ~s(placeholder="set")
    refute html =~ @upload_key
    assert_received {:put, %{"slots" => %{}}}

    no_name = view |> form("#phone-form", phone: %{name: "   "}) |> render_submit()
    assert no_name =~ "needs a name"

    html = view |> form("#phone-form", phone: %{name: "Work iPhone"}) |> render_submit()
    assert html =~ ~s(id="phone-qr")
    assert html =~ "<svg"
    assert [_, code] = Regex.run(~r/(dokkit-phone:1:[A-Za-z0-9_-]+)/, html)
    assert html =~ ~s(data-copy="#phone-code")
    assert html =~ "Work iPhone"
    assert_received {:put, %{"slots" => slots}}
    assert map_size(slots) == 1

    {:ok, view2, html2} = live(signed_in(conn), "/settings")
    assert html2 =~ "Work iPhone"
    refute html2 =~ code
    refute html2 =~ "phone-qr"

    [phone] = Phones.list()
    render_click(view2, "phone_remove", %{"id" => phone.id})
    assert Phones.list() == []
    assert_received {:put, %{"slots" => gone}}
    assert gone == %{}
  end

  test "a viewer sees no part of it and cannot use it", %{conn: conn} do
    viewer = Repo.insert!(%User{name: "vic", password_hash: "-", role: :viewer})

    {:ok, view, html} =
      live(
        Plug.Test.init_test_session(conn, %{
          "user_id" => viewer.id,
          "signed_at" => Dokkit.Accounts.stamp()
        }),
        "/settings"
      )

    refute html =~ "Relay address"
    render_submit(view, "relay_save", %{"relay" => @relay})
    render_submit(view, "phone_add", %{"phone" => %{"name" => "x"}})
    assert Phones.relay()["key"] == ""
    assert Phones.list() == []
  end
end
