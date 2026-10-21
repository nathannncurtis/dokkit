defmodule DokkitWeb.Auth do
  @moduledoc "Who is signed in, for pages and for live views."
  use DokkitWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  alias Dokkit.{Accounts, Demo}

  def fetch_user(conn, _), do: assign(conn, :current_user, user(get_session(conn)))

  def require_user(%{assigns: %{current_user: nil}} = conn, _),
    do: conn |> redirect(to: door()) |> halt()

  def require_user(conn, _), do: conn

  def on_mount(:user, _params, session, socket) do
    case user(session) do
      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: door())}

      user ->
        socket
        |> Phoenix.Component.assign(:current_user, user)
        |> shell()
        |> DokkitWeb.DemoSeat.keep(session)
    end
  end

  # What the sidebar shows, kept fresh on every page.
  defp shell(socket) do
    if Phoenix.LiveView.connected?(socket), do: Dokkit.Issues.subscribe()

    socket
    |> assign_shell()
    |> Phoenix.LiveView.attach_hook(:shell, :handle_info, fn
      :issues_changed, socket ->
        {:cont, debounce(socket, :shell, &assign_shell/1)}

      {:settled, :shell}, socket ->
        {:halt, settle(socket, :shell, &assign_shell/1)}

      :update_tick, socket ->
        {:halt, socket |> Phoenix.LiveView.put_private(:update_tick, false) |> assign_shell()}

      _, socket ->
        {:cont, socket}
    end)
  end

  @doc "Reloads at once, then at most once per `ms`, however many changes arrive."
  def debounce(socket, key, load, ms \\ 1000) do
    case Process.get({:debounce, key}) do
      nil ->
        Process.put({:debounce, key}, true)
        Process.send_after(self(), {:settled, key}, ms)
        load.(socket)

      _ ->
        Process.put({:debounce, key}, :pending)
        socket
    end
  end

  @doc "Run when the {:settled, key} timer fires: reloads once if changes came in meanwhile."
  def settle(socket, key, load, ms \\ 1000) do
    case Process.delete({:debounce, key}) do
      :pending -> debounce(socket, key, load, ms)
      _ -> socket
    end
  end

  defp assign_shell(socket) do
    shell = %{
      machines: Dokkit.Issues.machines(),
      open: Dokkit.Issues.open_count(),
      waiting: Dokkit.Found.count(),
      updating: Dokkit.UpdateRun.current(),
      failed: Dokkit.UpdateRun.failed(),
      demo: socket.assigns[:shell][:demo]
    }

    socket = Phoenix.Component.assign(socket, :shell, shell)

    # Nothing changes when a machine goes silent, so a running update is looked at again on a timer.
    if shell.updating && Phoenix.LiveView.connected?(socket) &&
         !socket.private[:update_tick] do
      Process.send_after(self(), :update_tick, 5000)
      Phoenix.LiveView.put_private(socket, :update_tick, true)
    else
      socket
    end
  end

  def sign_in(conn, user) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:user_id, user.id)
    |> put_session(:signed_at, Accounts.stamp())
    |> put_session(:live_socket_id, "user:#{user.id}")
  end

  @doc "The password was right; the session holds only who is still owed a code, for five minutes."
  def await_code(conn, user) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:code_for, user.id)
    |> put_session(:code_at, Accounts.stamp())
  end

  def awaiting_code(conn) do
    with id when is_binary(id) <- get_session(conn, :code_for),
         at when is_integer(at) <- get_session(conn, :code_at),
         true <- Accounts.stamp() - at < 300 * 1_000_000,
         %{totp_on: true} = user <- Accounts.get(id) do
      user
    else
      _ -> nil
    end
  end

  @doc "A demo seat signs in as the sample company's owner, without a password."
  def sign_in_demo(conn, seat) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:demo_seat, seat)
    |> put_session(:live_socket_id, "demo:#{seat}")
  end

  def sign_out(conn) do
    cond do
      Demo.on?() -> if(seat = get_session(conn, :demo_seat), do: Demo.leave(seat))
      user = conn.assigns[:current_user] -> Accounts.sign_out_everywhere(user)
      true -> nil
    end

    configure_session(conn, drop: true)
  end

  def door do
    cond do
      Demo.on?() -> ~p"/demo"
      Accounts.any?() -> ~p"/login"
      true -> ~p"/setup"
    end
  end

  @doc "Where a request came from. Behind a proxy every request comes from the proxy, so the address it appended is used."
  def address(conn) do
    with true <- Application.get_env(:dokkit, :behind_proxy, false),
         true <- proxy?(conn.remote_ip),
         [list | _] <- get_req_header(conn, "x-forwarded-for"),
         last = list |> String.split(",") |> List.last() |> String.trim(),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(last)) do
      ip
    else
      _ -> conn.remote_ip
    end
  end

  defp proxy?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: proxy?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})

  # The demo runs in a container, so its proxy reaches it from the container network's gateway.
  defp proxy?({172, b, _, 1}) when b in 16..31, do: Demo.on?()
  defp proxy?({127, _, _, _}), do: true
  defp proxy?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp proxy?(_), do: false

  defp user(%{"demo_seat" => seat}) do
    if Demo.on?() and Demo.seated?(seat), do: List.first(Accounts.list())
  end

  defp user(%{"user_id" => id, "signed_at" => at}) when is_integer(at) do
    user = Accounts.get(id)

    if user && at >= user.sessions_after &&
         Accounts.stamp() - at < Dokkit.Values.get("session_days") * 86_400 * 1_000_000,
       do: user
  end

  defp user(_), do: nil
end
