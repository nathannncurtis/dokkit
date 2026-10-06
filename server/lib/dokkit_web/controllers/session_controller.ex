defmodule DokkitWeb.SessionController do
  use DokkitWeb, :controller
  alias Dokkit.Accounts
  alias DokkitWeb.Auth

  plug :put_layout, false

  def new(conn, _) do
    if Accounts.any?(),
      do: render(conn, :login, error: nil, name: ""),
      else: redirect(conn, to: ~p"/setup")
  end

  def create(conn, %{"name" => name, "password" => password}) do
    case Accounts.authenticate(name, password) do
      {:ok, user} ->
        conn |> Auth.sign_in(user) |> redirect(to: ~p"/")

      :error ->
        # A fixed wait on top of the hash. A limit per address belongs with the reverse proxy.
        Process.sleep(500)

        conn
        |> put_status(401)
        |> render(:login, error: "That name and password do not match.", name: name)
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
end
