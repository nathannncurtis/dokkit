defmodule DokkitWeb.EnrolLiveTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "the page shows how to get the dokkit program", %{conn: conn} do
    {:ok, _view, html} = live(signed_in(conn), "/machines/new")
    assert html =~ "curl -fsSL https://dokkit.dev/get.sh | sh"
    assert html =~ "irm https://dokkit.dev/get.ps1 | iex"
    refute html =~ "dokkit enrol"
  end

  test "a token comes with the commands for how the machine will run, a copy button and a countdown",
       %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn), "/machines/new")

    html = view |> form("#token-form", mode: "service") |> render_submit()
    assert html =~ ~r/dokkit enrol \S+ dke_\w{36}\ndokkit service install/
    assert html =~ ~s(data-copy="#enrol-commands")
    assert html =~ "Waiting for the machine"
    assert html =~ "runs out in 3 h 5"
    assert html =~ "dokkit folder add"

    html = view |> form("#token-form", mode: "login") |> render_change()
    assert html =~ ~r/dke_\w{36}\ndokkit watch/
    refute html =~ "dokkit service install"
  end

  test "a token made for a name carries it, and the page shows the machine when it enrols",
       %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn), "/machines/new")
    html = view |> form("#token-form", name: "front-desk") |> render_submit()
    [token] = Regex.run(~r/dke_\w{36}/, html)
    assert {:ok, %{label: "front-desk"}} = Dokkit.Keys.verify(token, :enrol)

    assert {:ok, _} = Dokkit.Intake.enrol(token, %{"hostname" => "front-desk", "os" => "linux"})
    send(view.pid, :tick)
    html = render(view)
    assert html =~ "front-desk"
    assert html =~ "is enrolled"
    refute html =~ "Waiting for the machine"
  end
end
