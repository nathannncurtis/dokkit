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

    conn = from(conn, 15)

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

  defp from(conn, n), do: Map.put(conn, :remote_ip, {10, 0, 0, n})

  test "repeated wrong passwords from one address for one name are refused before the check", %{
    conn: conn
  } do
    {:ok, _} = Accounts.add("throttled-tess", "member", @password)
    conn = from(conn, 11)

    for _ <- 1..10,
        do: assert(response(post(conn, "/login", %{name: "throttled-tess", password: "no"}), 401))

    blocked = post(conn, "/login", %{name: "Throttled-Tess", password: @password})
    assert html_response(blocked, 429) =~ "Too many attempts"
    assert get_resp_header(blocked, "retry-after") == ["600"]
  end

  test "guessing in parallel is counted before the passwords are hashed", %{conn: conn} do
    {:ok, _} = Accounts.add("parallel-pam", "member", @password)
    conn = from(conn, 12)

    codes =
      1..20
      |> Task.async_stream(
        fn _ -> post(conn, "/login", %{name: "parallel-pam", password: "no"}).status end,
        max_concurrency: 20,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, status} -> status end)

    assert Enum.count(codes, &(&1 == 401)) <= 10
    assert Enum.count(codes, &(&1 == 429)) >= 10
  end

  test "a name guessed from other addresses is slowed, not locked out", %{conn: conn} do
    {:ok, _} = Accounts.add("slowed-sid", "member", @password)

    for n <- 1..10,
        do: Dokkit.LoginThrottle.attempt("slowed-sid", {10, 1, 0, n})

    ok = post(from(conn, 13), "/login", %{name: "slowed-sid", password: @password})
    assert redirected_to(ok) == "/"
  end

  test "an address is refused after 30 attempts, and a good sign-in gives one back" do
    ip = {10, 2, 0, 1}
    for n <- 1..30, do: assert(Dokkit.LoginThrottle.attempt("addr-#{n}", ip) == :ok)
    assert Dokkit.LoginThrottle.attempt("addr-31", ip) == :blocked

    ip = {10, 2, 0, 2}
    for n <- 1..30, do: Dokkit.LoginThrottle.attempt("back-#{n}", ip)
    Dokkit.LoginThrottle.refund("back-1", ip)
    assert Dokkit.LoginThrottle.attempt("back-31", ip) == :ok
  end

  test "signing out ends copies of the session, and old sessions expire", %{conn: conn} do
    {:ok, user} = Accounts.add("session-sue", "member", @password)
    inside = post(from(conn, 16), "/login", %{name: "session-sue", password: @password})
    copy = recycle(inside)
    assert html_response(get(copy, "/"), 200) =~ "Inbox"

    post(recycle(inside), "/logout")
    assert redirected_to(get(copy, "/")) == "/login"

    old = Accounts.stamp() - 15 * 86_400 * 1_000_000
    stale = Plug.Test.init_test_session(build_conn(), %{"user_id" => user.id, "signed_at" => old})
    assert redirected_to(get(stale, "/")) == "/login"
  end

  test "changing a password needs the old one, ends other sessions and keeps this one", %{
    conn: conn
  } do
    {:ok, pat} = Accounts.add("password-pat", "member", @password)
    DokkitWeb.Endpoint.subscribe("user:#{pat.id}")
    conn = from(conn, 14)
    inside = post(conn, "/login", %{name: "password-pat", password: @password})
    other = recycle(inside)

    wrong =
      post(recycle(inside), "/password", %{old: "not it at all", new: "another long phrase"})

    assert html_response(wrong, 422) =~ "not your current password"

    short = post(recycle(inside), "/password", %{old: @password, new: "short"})
    assert html_response(short, 422) =~ "at least 12"

    done = post(recycle(inside), "/password", %{old: @password, new: "another long phrase"})
    assert html_response(done, 200) =~ "is changed"
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    assert html_response(get(recycle(done), "/"), 200) =~ "Inbox"
    assert redirected_to(get(other, "/")) == "/login"
    assert {:ok, _} = Accounts.authenticate("password-pat", "another long phrase")
    assert Accounts.authenticate("password-pat", @password) == :error
  end

  test "with two-step sign-in on, the password alone does not sign in and a code works once", %{
    conn: conn
  } do
    {:ok, user} = Accounts.add("totp-tom", "member", @password)
    conn = from(conn, 21)
    inside = recycle(post(conn, "/login", %{name: "totp-tom", password: @password}))

    page = html_response(get(inside, "/two-step"), 200)
    assert page =~ "<svg"
    secret = Accounts.get(user.id).totp_secret
    assert page =~ secret

    assert html_response(get(inside, "/two-step"), 200) =~ secret
    assert Accounts.get(user.id).totp_secret == secret

    assert html_response(post(inside, "/two-step", %{code: "000000"}), 422) =~ "not right"
    assert Accounts.get(user.id).totp_secret == secret
    code = Accounts.totp_code(secret)

    assert html_response(post(inside, "/two-step", %{code: code}), 200) =~
             "Two-step sign-in is on"

    half = post(conn, "/login", %{name: "totp-tom", password: @password})
    assert redirected_to(half) == "/login/code"
    half = recycle(half)
    assert redirected_to(get(half, "/")) == "/login"
    assert html_response(post(half, "/login/code", %{code: code}), 401) =~ "work once"

    next = Accounts.totp_code(secret, Accounts.totp_step() + 1)
    done = post(half, "/login/code", %{code: next})
    assert redirected_to(done) == "/"
    assert html_response(get(recycle(done), "/"), 200) =~ "Inbox"

    assert redirected_to(get(conn, "/login/code")) == "/login"
    Accounts.totp_reset("Totp-Tom")
    assert redirected_to(post(conn, "/login", %{name: "totp-tom", password: @password})) == "/"
  end
end
