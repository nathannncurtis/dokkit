defmodule DokkitWeb.Auth do
  @moduledoc "Who is signed in, for pages and for live views."
  use DokkitWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  alias Dokkit.Accounts

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
      :issues_changed, socket -> {:cont, assign_shell(socket)}
      _, socket -> {:cont, socket}
    end)
  end

  defp assign_shell(socket) do
    shell = %{
      machines: Dokkit.Issues.machines(),
      open: Dokkit.Issues.open_count(),
      waiting: Dokkit.Tasks.waiting_count() + Dokkit.Found.count()
    }

    Phoenix.Component.assign(socket, :shell, shell)
  end

  def sign_in(conn, user) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:user_id, user.id)
    |> put_session(:live_socket_id, "user:#{user.id}")
  end

  def sign_out(conn) do
    if id = get_session(conn, :live_socket_id),
      do: DokkitWeb.Endpoint.broadcast(id, "disconnect", %{})

    configure_session(conn, drop: true)
  end

  def door, do: if(Accounts.any?(), do: ~p"/login", else: ~p"/setup")

  defp user(%{"user_id" => id}), do: Accounts.get(id)
  defp user(_), do: nil
end
