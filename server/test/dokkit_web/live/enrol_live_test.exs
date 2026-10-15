defmodule DokkitWeb.EnrolLiveTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "the page shows how to get the dokkit program", %{conn: conn} do
    {:ok, view, html} = live(signed_in(conn), "/machines/new")
    refute html =~ "dokkit enrol"
    html = view |> form("#token-form", os: "linux") |> render_change()
    assert html =~ "curl -fsSL https://dokkit.dev/get.sh | sh"
  end

  test "a token comes with the commands for how the machine will run, a copy button and a countdown",
       %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn), "/machines/new")

    view |> form("#token-form", os: "linux") |> render_change()
    html = view |> form("#token-form", os: "linux", mode: "service") |> render_submit()
    assert html =~ ~r/dokkit enrol \S+ dke_\w{36}\ndokkit service install/
    assert html =~ ~r/id="enrol-line-1"[^>]*>dokkit enrol/
    assert html =~ ~r/id="enrol-line-2"[^>]*>dokkit service install/
    assert html =~ ~s(data-copy="#enrol-commands")
    assert html =~ ~s(data-copy="#enrol-line-1")
    assert html =~ ~s(data-copy="#enrol-line-2")
    assert html =~ "Waiting for the machine"
    assert html =~ ~r/runs out in (4 h 0|3 h 59)/
    assert html =~ "dokkit folder add"

    html = view |> form("#token-form", os: "linux", mode: "login") |> render_change()
    assert html =~ ~r/dke_\w{36}\ndokkit watch/
    refute html =~ "dokkit service install"
  end

  test "a token made for a name carries it, and the page shows the machine when it enrols",
       %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn), "/machines/new")
    html = view |> form("#token-form", os: "linux", name: "front-desk") |> render_submit()
    [token] = Regex.run(~r/dke_\w{36}/, html)
    assert {:ok, %{label: "front-desk"}} = Dokkit.Keys.verify(token, :enrol)

    assert {:ok, _} = Dokkit.Intake.enrol(token, %{"hostname" => "front-desk", "os" => "linux"})
    send(view.pid, :tick)
    html = render(view)
    assert html =~ "front-desk"
    assert html =~ "is spent"
    refute html =~ "Waiting for the machine"
  end

  test "tokens made and not used are listed with time left and can be revoked", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn), "/machines/new")
    refute render(view) =~ "Tokens waiting"

    html = view |> form("#token-form", os: "linux", name: "back-room") |> render_submit()
    [token] = Regex.run(~r/dke_\w{36}/, html)
    assert html =~ "Tokens waiting"
    assert html =~ ~r/id="waiting-[^"]+".*back-room/s
    assert html =~ ~r/(3 h 59|4 h 0) min/

    {:ok, %{id: id}} = Dokkit.Keys.verify(token, :enrol)
    html = view |> element("#waiting-#{id} button", "Revoke") |> render_click()
    refute html =~ "Tokens waiting"
    assert html =~ "The token was revoked"
    assert Dokkit.Keys.verify(token, :enrol) == :error
  end

  test "the page names the machine a token became, even when the host is named otherwise",
       %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn), "/machines/new")
    html = view |> form("#token-form", os: "linux", name: "") |> render_submit()
    [token] = Regex.run(~r/dke_\w{36}/, html)
    {:ok, key} = Dokkit.Keys.verify(token, :enrol)

    assert {:ok, %{machine: id}} = Dokkit.Intake.enrol(token, %{"hostname" => "pc-9"})
    assert %{id: ^id} = Dokkit.Keys.arrived(key)
    send(view.pid, :tick)
    html = render(view)
    assert html =~ "pc-9"
    assert html =~ "is spent"
  end
end
