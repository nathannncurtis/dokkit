defmodule DokkitWeb.DemoSeat do
  @moduledoc "Keeps a demo seat on every page: what counts as being there, what is turned off, and the Still there? bar."
  import Phoenix.LiveView
  alias Dokkit.Demo

  # Each of these sends something out, locks other visitors out, or changes the server itself.
  @off %{
    DokkitWeb.SettingsLive =>
      ~w(relay_save relay_shared phone_add phone_remove add remove restore revoke token full full_token certificate_save acme_save acme_now name_claim retention_save certificate_remove values_save values_reset),
    DokkitWeb.AlertsLive => ~w(save test beat_shared beat_stop person)
  }

  def off?(view, event), do: event in Map.get(@off, view, [])

  def keep(socket, session) do
    seat = session["demo_seat"]

    cond do
      not Demo.on?() ->
        {:cont, socket}

      connected?(socket) and Demo.attach(seat, self()) == :gone ->
        {:halt, redirect(socket, to: "/demo/away?why=gone")}

      true ->
        {:cont,
         socket
         |> put(%{warn: nil, note: nil})
         |> attach_hook(:demo_page, :handle_params, fn _, uri, s ->
           Demo.act(seat, {:page, uri})
           {:cont, Phoenix.Component.assign(s, :demo_uri, uri)}
         end)
         |> attach_hook(:demo_event, :handle_event, &event(seat, &1, &2, &3))
         |> attach_hook(:demo_info, :handle_info, &info/2)}
    end
  end

  defp event(seat, "demo_here", _, s) do
    case Demo.here(seat) do
      :ok -> {:halt, s}
      :no -> {:halt, put(s, %{note: "Open a page or use a control to keep your seat."})}
    end
  end

  defp event(seat, event, params, s) do
    if off?(s.view, event) do
      {:halt, put(s, %{note: "That is turned off in the demo."})}
    else
      Demo.act(seat, {s.view, event, params})
      {:cont, put(s, %{note: nil})}
    end
  end

  defp info({:demo, {:warn, _, spot}}, s), do: {:halt, put(s, %{warn: spot})}
  defp info({:demo, :back}, s), do: {:halt, put(s, %{warn: nil, note: nil})}
  defp info({:demo, {:away, why}}, s), do: {:halt, redirect(s, to: "/demo/away?why=#{why}")}

  defp info({:demo, :reload}, s) do
    %{path: path, query: query} = URI.parse(s.assigns[:demo_uri] || "/")
    {:halt, push_navigate(s, to: if(query, do: "#{path}?#{query}", else: path))}
  end

  defp info(_, s), do: {:cont, s}

  defp put(s, changes) do
    shell = s.assigns[:shell] || %{}

    Phoenix.Component.assign(
      s,
      :shell,
      Map.put(shell, :demo, Map.merge(shell[:demo] || %{}, changes))
    )
  end
end
