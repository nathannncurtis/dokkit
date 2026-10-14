defmodule DokkitWeb.Auth do
  @moduledoc "Who is signed in, for pages and for live views."
  use DokkitWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  alias Dokkit.Accounts

  @session_seconds 14 * 86_400

  def fetch_user(conn, _), do: assign(conn, :current_user, user(get_session(conn)))

  def require_user(%{assigns: %{current_user: nil}} = conn, _),
    do: conn |> redirect(to: door()) |> halt()

  def require_user(conn, _), do: conn

  def on_mount(:user, _params, session, socket) do
    case user(session) do
      nil -> {:halt, Phoenix.LiveView.redirect(socket, to: door())}
      user -> {:cont, socket |> Phoenix.Component.assign(:current_user, user) |> shell()}
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
      failed: Dokkit.UpdateRun.failed()
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

  def sign_out(conn) do
    if user = conn.assigns[:current_user], do: Accounts.sign_out_everywhere(user)

    configure_session(conn, drop: true)
  end

  def door, do: if(Accounts.any?(), do: ~p"/login", else: ~p"/setup")

  defp user(%{"user_id" => id, "signed_at" => at}) when is_integer(at) do
    user = Accounts.get(id)

    if user && at >= user.sessions_after && Accounts.stamp() - at < @session_seconds * 1_000_000,
      do: user
  end

  defp user(_), do: nil
end
