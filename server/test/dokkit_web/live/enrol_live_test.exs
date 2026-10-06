defmodule DokkitWeb.EnrolLiveTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "the page shows how to get the dokkit program", %{conn: conn} do
    {:ok, _view, html} = live(signed_in(conn), "/machines/new")
    assert html =~ "curl -fsSL https://dokkit.dev/get.sh | sh"
    assert html =~ "irm https://dokkit.dev/get.ps1 | iex"
  end
end
