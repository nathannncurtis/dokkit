defmodule DokkitWeb.SettingsLiveTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Dokkit.{Accounts, Keys, Repo, User}

  test "the owner adds and removes people, revokes keys and makes tokens", %{conn: conn} do
    {app, key} = Keys.mint(:app, %{label: "Nightly backup"})
    {:ok, view, html} = live(signed_in(conn), "/settings")
    assert html =~ "Nightly backup"
    assert html =~ "App key"
    refute html =~ app

    short =
      view
      |> form("#person-form", person: %{name: "vic", role: "viewer", password: "short"})
      |> render_submit()

    assert short =~ "at least 12"

    html =
      view
      |> form("#person-form", person: %{name: "vic", role: "viewer", password: "a long password"})
      |> render_submit()

    assert html =~ "vic"
    assert {:ok, %User{role: :viewer} = vic} = Accounts.authenticate("VIC", "a long password")

    again =
      view
      |> form("#person-form", person: %{name: "Vic", role: "member", password: "a long password"})
      |> render_submit()

    assert again =~ "already someone called"

    render_click(view, "remove", %{"id" => vic.id})
    assert Accounts.authenticate("vic", "a long password") == :error
    me = Repo.get_by!(User, name: "sam")
    assert render_click(view, "remove", %{"id" => me.id}) =~ "cannot remove yourself"

    render_click(view, "revoke", %{"id" => key.id})
    assert Keys.verify(app, :app) == :error
    refute render(view) =~ "Nightly backup"

    none = render_submit(view, "token", %{"token" => %{"label" => "script"}})
    assert none =~ "at least one thing"

    html =
      view
      |> form("#token-form",
        token: %{"label" => "laptop script", "read" => "true", "read-logs" => "true"}
      )
      |> render_submit()

    [token] = Regex.run(~r/dku_\w{36}/, html)
    assert {:ok, %{scopes: ["read", "read-logs"]}} = Keys.verify(token, :user)
  end

  test "a viewer sees no forms and can change nothing", %{conn: conn} do
    viewer = Repo.insert!(%User{name: "vic", password_hash: "-", role: :viewer})
    {_, key} = Keys.mint(:app, %{label: "x"})

    {:ok, view, html} =
      live(
        Plug.Test.init_test_session(conn, %{
          "user_id" => viewer.id,
          "signed_at" => Dokkit.Accounts.stamp()
        }),
        "/settings"
      )

    refute html =~ "Add person"
    refute html =~ "Make a token"
    render_click(view, "revoke", %{"id" => key.id})

    render_click(view, "add", %{
      "person" => %{"name" => "eve", "role" => "owner", "password" => "a long password"}
    })

    assert length(Keys.list()) == 1
    assert length(Accounts.list()) == 1
  end
end
