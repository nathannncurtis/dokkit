defmodule DokkitWeb.SessionControllerTest do
  use DokkitWeb.ConnCase, async: true
  alias Dokkit.Accounts

  @password "correct horse battery"

  test "the setup code claims a new server once, then people sign in", %{conn: conn} do
    assert html_response(get(conn, "/setup"), 200) =~ "Setup code"
    assert redirected_to(get(conn, "/login")) == "/setup"
    assert redirected_to(get(conn, "/")) == "/setup"

    wrong = post(conn, "/setup", %{code: "AAAA-AAAA", name: "sam", password: @password})
    assert html_response(wrong, 422) =~ "not the setup code"
    refute Accounts.any?()

    short = post(conn, "/setup", %{code: Accounts.setup_code(), name: "sam", password: "short"})
    assert html_response(short, 422) =~ "at least 12"

    claimed =
      post(conn, "/setup", %{
        code: String.downcase(Accounts.setup_code()),
        name: "sam",
        password: @password
      })

    assert redirected_to(claimed) == "/"
    assert html_response(get(recycle(claimed), "/"), 200) =~ "Inbox"

    again = post(conn, "/setup", %{code: Accounts.setup_code(), name: "eve", password: @password})
    assert html_response(again, 422) =~ "already has an owner"
    assert redirected_to(get(conn, "/setup")) == "/login"

    assert html_response(post(conn, "/login", %{name: "sam", password: "wrong password!"}), 401) =~
             "do not match"

    assert html_response(post(conn, "/login", %{name: "nobody", password: @password}), 401) =~
             "do not match"

    inside = post(conn, "/login", %{name: "Sam", password: @password})
    assert redirected_to(inside) == "/"

    out = post(recycle(inside), "/logout")
    assert redirected_to(out) == "/login"
    assert redirected_to(get(recycle(out), "/")) == "/login"
  end
end
