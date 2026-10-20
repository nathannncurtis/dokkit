defmodule DokkitWeb.DemoTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    Application.put_env(:dokkit, :demo, true)
    Application.put_env(:dokkit, :demo_limits, %{seats: 1})
    start_supervised!({Dokkit.Demo, build: false, reset: false})
    Dokkit.Repo.insert!(%Dokkit.User{name: "sample", password_hash: "-", role: :owner})

    on_exit(fn ->
      Application.delete_env(:dokkit, :demo)
      Application.delete_env(:dokkit, :demo_limits)
    end)
  end

  defp seat(conn) do
    conn = get(conn, ~p"/demo")
    assert redirected_to(conn) == ~p"/"
    conn |> recycle() |> Map.put(:remote_ip, conn.remote_ip)
  end

  test "one click takes a seat, without a password", %{conn: conn} do
    conn = seat(conn)
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "This is the Dokkit demo"
    assert redirected_to(get(build_conn(), ~p"/login")) == ~p"/demo"
    assert redirected_to(get(conn, ~p"/password")) == ~p"/demo"
  end

  test "a full demo puts people in line and hands the freed seat to the first", %{conn: conn} do
    first = seat(conn)
    other = %{build_conn() | remote_ip: {10, 0, 0, 2}}
    other = get(other, ~p"/demo")
    assert html_response(other, 200) =~ "The demo is full"
    assert html_response(other, 200) =~ "You're 1st in line"
    other = recycle(other)

    assert %{"state" => "waiting", "place" => 1, "taken" => 1} =
             json_response(get(other, ~p"/demo/line"), 200)

    left = post(first, ~p"/logout")
    assert redirected_to(left) == ~p"/demo/away?why=left"

    assert %{"state" => "turn"} = json_response(get(recycle(other), ~p"/demo/line"), 200)
    taken = post(recycle(other), ~p"/demo/seat")
    assert redirected_to(taken) == ~p"/"
  end

  test "one address holds at most three seats or places", %{conn: conn} do
    seat(conn)

    codes =
      for _ <- 1..3 do
        %{build_conn() | remote_ip: {127, 0, 0, 1}} |> get(~p"/demo") |> Map.get(:status)
      end

    assert codes == [200, 200, 429]
  end

  test "turned-off controls say so and change nothing", %{conn: conn} do
    {:ok, view, _} = live(seat(conn), ~p"/settings")
    assert render_click(view, "relay_shared", %{}) =~ "That is turned off in the demo."
  end

  test "Still there? shows, I'm here keeps the seat, and an idle seat leaves the demo", %{
    conn: conn
  } do
    {:ok, view, _} = live(seat(conn), ~p"/")
    send(view.pid, {:demo, {:warn, 60, {10, 20}}})
    assert render(view) =~ "Still there?"
    render_click(view, "demo_here", %{})
    refute render(view) =~ "Still there?"
    send(view.pid, {:demo, {:away, :idle}})
    assert_redirect(view, "/demo/away?why=idle")
  end

  test "the demo's door is closed when the demo is off", %{conn: conn} do
    Application.delete_env(:dokkit, :demo)
    assert get(conn, ~p"/demo").status == 404
  end
end
