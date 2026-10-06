defmodule DokkitWeb.SessionController do
  use DokkitWeb, :controller
  alias Dokkit.{Accounts, LoginThrottle}
  alias DokkitWeb.Auth

  @too_many "Too many attempts. Wait ten minutes and try again."

  plug :put_layout, false

  def new(conn, _) do
    if Accounts.any?(),
      do: render(conn, :login, error: nil, name: ""),
      else: redirect(conn, to: ~p"/setup")
  end

  def create(conn, %{"name" => name, "password" => password}) when is_binary(name) do
    key = String.downcase(String.trim(name))
    address = address(conn)

    if LoginThrottle.attempt(key, address) == :blocked do
      conn |> blocked() |> render(:login, error: @too_many, name: name)
    else
      case Accounts.authenticate(name, password) do
        {:ok, user} ->
          LoginThrottle.refund(key, address)
          conn |> Auth.sign_in(user) |> redirect(to: ~p"/")

        :error ->
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
    address = address(conn)

    if LoginThrottle.attempt(key, address) == :blocked do
      conn |> blocked() |> render(:password, error: @too_many, done: false)
    else
      case Accounts.change_password(user, old, new) do
        {:ok, user} ->
          LoginThrottle.refund(key, address)
          conn |> Auth.sign_in(user) |> render(:password, error: nil, done: true)

        {:error, :wrong, message} ->
          conn |> put_status(422) |> render(:password, error: message, done: false)

        {:error, message} ->
          LoginThrottle.refund(key, address)
          conn |> put_status(422) |> render(:password, error: message, done: false)
      end
    end
  end

  defp blocked(conn), do: conn |> put_resp_header("retry-after", "600") |> put_status(429)

  # Behind a proxy every request comes from the proxy, so the address it appended is used.
  defp address(conn) do
    with true <- Application.get_env(:dokkit, :behind_proxy, false),
         [list | _] <- get_req_header(conn, "x-forwarded-for"),
         last = list |> String.split(",") |> List.last() |> String.trim(),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(last)) do
      ip
    else
      _ -> conn.remote_ip
    end
  end
end
