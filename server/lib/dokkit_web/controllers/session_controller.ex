defmodule DokkitWeb.SessionController do
  use DokkitWeb, :controller
  alias Dokkit.{Accounts, LoginThrottle}
  alias DokkitWeb.Auth

  plug :put_layout, false

  def new(conn, _) do
    if Accounts.any?(),
      do: render(conn, :login, error: nil, name: ""),
      else: redirect(conn, to: ~p"/setup")
  end

  def create(conn, %{"name" => name, "password" => password}) when is_binary(name) do
    key = String.downcase(String.trim(name))
    address = conn.remote_ip

    if LoginThrottle.blocked?(key, address) do
      conn
      |> put_resp_header("retry-after", "600")
      |> put_status(429)
      |> render(:login, error: "Too many attempts. Wait ten minutes and try again.", name: name)
    else
      case Accounts.authenticate(name, password) do
        {:ok, user} ->
          LoginThrottle.cleared(key)
          conn |> Auth.sign_in(user) |> redirect(to: ~p"/")

        :error ->
          LoginThrottle.failed(key, address)
          Process.sleep(500)

          conn
          |> put_status(401)
          |> render(:login, error: "That name and password do not match.", name: name)
      end
    end
  end

  def delete(conn, _), do: conn |> Auth.sign_out() |> redirect(to: ~p"/login")

  def setup(conn, _) do
    if Accounts.any?(),
      do: redirect(conn, to: ~p"/login"),
      else: render(conn, :setup, error: nil, name: "")
  end

  def claim(conn, %{"code" => code, "name" => name, "password" => password}) do
    case Accounts.create_owner(code, name, password) do
      {:ok, user} -> conn |> Auth.sign_in(user) |> redirect(to: ~p"/")
      {:error, message} -> conn |> put_status(422) |> render(:setup, error: message, name: name)
    end
  end

  def password(conn, _), do: render(conn, :password, error: nil, done: false)

  def change_password(conn, %{"old" => old, "new" => new}) do
    user = conn.assigns.current_user
    key = String.downcase(user.name)

    result =
      if LoginThrottle.blocked?(key, conn.remote_ip),
        do: {:error, "Too many attempts. Wait ten minutes and try again."},
        else: Accounts.change_password(user, old, new)

    case result do
      {:ok, user} ->
        conn |> Auth.sign_in(user) |> render(:password, error: nil, done: true)

      {:error, message} ->
        LoginThrottle.failed(key, conn.remote_ip)
        conn |> put_status(422) |> render(:password, error: message, done: false)
    end
  end
end
