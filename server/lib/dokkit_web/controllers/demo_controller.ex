defmodule DokkitWeb.DemoController do
  @moduledoc "The demo's door: a seat at once if one is free, else a place in line."
  use DokkitWeb, :controller
  alias Dokkit.Demo
  alias DokkitWeb.Auth

  plug :put_layout, false
  plug :demo_only

  def show(conn, _) do
    ticket = get_session(conn, :demo_ticket)

    cond do
      conn.assigns.current_user ->
        redirect(conn, to: ~p"/")

      ticket && Demo.poll(ticket) != :gone ->
        render_line(conn, ticket)

      true ->
        case Demo.take(Auth.address(conn)) do
          {:seat, seat} -> conn |> Auth.sign_in_demo(seat) |> redirect(to: ~p"/")
          {:line, ticket} -> conn |> put_session(:demo_ticket, ticket) |> render_line(ticket)
          :address_limit -> conn |> put_status(429) |> render(:limit, page_title: "Demo")
        end
    end
  end

  def line(conn, _) do
    stats = Demo.stats()

    case get_session(conn, :demo_ticket) && Demo.poll(get_session(conn, :demo_ticket)) do
      {:waiting, place} -> json(conn, Map.merge(stats, %{state: "waiting", place: place}))
      {:turn, _} -> json(conn, Map.put(stats, :state, "turn"))
      _ -> json(conn, Map.put(stats, :state, "gone"))
    end
  end

  def seat(conn, _) do
    case Demo.claim(get_session(conn, :demo_ticket)) do
      {:seat, seat} -> conn |> Auth.sign_in_demo(seat) |> redirect(to: ~p"/")
      :gone -> conn |> delete_session(:demo_ticket) |> redirect(to: ~p"/demo")
    end
  end

  def away(conn, params) do
    conn |> delete_session(:demo_seat) |> render(:away, why: params["why"], page_title: "Demo")
  end

  defp render_line(conn, ticket) do
    {place, turn} =
      case Demo.poll(ticket) do
        {:waiting, place} -> {place, false}
        _ -> {nil, true}
      end

    render(conn, :line,
      place: place,
      turn: turn,
      stats: Demo.stats(),
      page_title: "The demo is full"
    )
  end

  defp demo_only(conn, _),
    do: if(Demo.on?(), do: conn, else: conn |> send_resp(404, "Not found") |> halt())
end
