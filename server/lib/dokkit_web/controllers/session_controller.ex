defmodule DokkitWeb.SessionController do
  use DokkitWeb, :controller
  alias Dokkit.{Accounts, LoginThrottle}
  alias DokkitWeb.Auth

  @too_many "Too many attempts. Wait ten minutes and try again."

  @wrong_code "That code is not right. Codes change every 30 seconds and work once."

  @shown_once "Recovery codes are shown once, when two-step sign-in is turned on or a new set is made. To get a new set, enter a code and choose Make new recovery codes."

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

          if user.totp_on,
            do: conn |> Auth.await_code(user) |> redirect(to: ~p"/login/code"),
            else: conn |> Auth.sign_in(user) |> redirect(to: ~p"/")

        :error ->
          Process.sleep(500)

          conn
          |> put_status(401)
          |> render(:login, error: "That name and password do not match.", name: name)
      end
    end
  end

  def code(conn, _) do
    if Auth.awaiting_code(conn),
      do: render(conn, :code, error: nil),
      else: redirect(conn, to: ~p"/login")
  end

  def check_code(conn, %{"code" => code}) do
    user = Auth.awaiting_code(conn)

    cond do
      user == nil ->
        redirect(conn, to: ~p"/login")

      LoginThrottle.attempt(String.downcase(user.name), address(conn)) == :blocked ->
        conn |> blocked() |> render(:code, error: @too_many)

      Accounts.totp_check(user, code) ->
        LoginThrottle.refund(String.downcase(user.name), address(conn))
        conn |> Auth.sign_in(user) |> redirect(to: ~p"/")

      Accounts.recovery_use(user, code) ->
        LoginThrottle.refund(String.downcase(user.name), address(conn))
        conn |> Auth.sign_in(user) |> redirect(to: ~p"/two-step?used=1")

      true ->
        conn |> put_status(401) |> render(:code, error: @wrong_code)
    end
  end

  def two_step(conn, params), do: render_two_step(conn, nil, params["used"] == "1")

  def change_two_step(conn, %{"do" => "on", "code" => _} = params) do
    if conn.assigns.current_user.totp_on,
      do: render_two_step(conn, @shown_once),
      else: change_two_step(conn, Map.delete(params, "do"))
  end

  def change_two_step(conn, %{"code" => code} = params) do
    user = conn.assigns.current_user
    key = String.downcase(user.name)
    address = address(conn)

    if LoginThrottle.attempt(key, address) == :blocked do
      conn |> blocked() |> render_two_step(@too_many)
    else
      result =
        cond do
          not user.totp_on -> Accounts.totp_confirm(user, code)
          params["do"] == "codes" -> Accounts.recovery_renew(user, code)
          true -> Accounts.totp_off(user, code)
        end

      case result do
        {:ok, codes} ->
          LoginThrottle.refund(key, address)

          conn
          |> put_resp_header("cache-control", "no-store")
          |> assign(:current_user, Accounts.get(user.id))
          |> render(:codes, codes: codes)

        :ok ->
          LoginThrottle.refund(key, address)
          conn |> assign(:current_user, Accounts.get(user.id)) |> render_two_step(nil)

        :error ->
          conn |> put_status(422) |> render_two_step(@wrong_code)
      end
    end
  end

  # One unconfirmed secret is kept until it is confirmed, so a reload or a second tab shows the QR code already scanned.
  defp render_two_step(conn, error, used \\ false) do
    user = conn.assigns.current_user

    secret = if !user.totp_on, do: user.totp_secret || Accounts.totp_begin(user)

    qr = secret && Accounts.totp_uri(user, secret) |> EQRCode.encode() |> EQRCode.svg(width: 220)
    left = if user.totp_on, do: Accounts.recovery_left(user)

    render(conn, :two_step,
      error: error,
      on: user.totp_on,
      secret: secret,
      qr: qr,
      left: left,
      used: used
    )
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
         true <- loopback?(conn.remote_ip),
         [list | _] <- get_req_header(conn, "x-forwarded-for"),
         last = list |> String.split(",") |> List.last() |> String.trim(),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(last)) do
      ip
    else
      _ -> conn.remote_ip
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, _}), do: true
  defp loopback?(_), do: false
end
