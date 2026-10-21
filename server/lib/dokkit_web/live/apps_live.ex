defmodule DokkitWeb.AppsLive do
  use DokkitWeb, :live_view

  def mount(_params, _session, socket),
    do: {:ok, load(assign(socket, page_title: "Apps"))}

  def handle_info(:issues_changed, socket),
    do: {:noreply, DokkitWeb.Auth.debounce(socket, :page, &load/1)}

  def handle_info({:settled, :page}, socket),
    do: {:noreply, DokkitWeb.Auth.settle(socket, :page, &load/1)}

  defp load(socket) do
    attention = Enum.frequencies_by(Dokkit.Issues.groups().needs_you, & &1.service_id)

    rows =
      for m <- Dokkit.Estate.machines(), m.kind == :group, s <- m.services do
        %{
          service: s,
          group: m.name,
          attention: attention[s.id] || 0,
          last: Dokkit.Estate.last_reported(s)
        }
      end
      |> Enum.sort_by(&{-&1.attention, String.downcase(&1.service.name)})

    {silent, reported} = Enum.split_with(rows, &(&1.service.state == :unknown))
    assign(socket, reported: reported, silent: silent)
  end

  defp need(0), do: "Nothing"
  defp need(1), do: "1 needs a look"
  defp need(n), do: "#{n} need a look"

  attr :rows, :list, required: true

  defp rows(assigns) do
    ~H"""
    <.link :for={r <- @rows} class="li slim cols-all ap" navigate={~p"/s/#{r.service.id}"}>
      <div class="ti">
        <.lvl state={r.service.state} /><span>{r.service.name}</span>
      </div>
       <span class="mono mute">{r.service.version}</span>
      <span class="mono mute">{(r.last && "#{at(r.last)} UTC") || "Never"}</span>
      <span class={["tag", r.service.state in [:degraded, :down] && "warn"]}>{(!r.service.watched &&
                                                                                 "Not watched") ||
        r.service.note || say(r.service.state)}</span>
      <span class={["st", r.attention > 0 && "warn"]}>{need(r.attention)}</span>
      <.ic name="caret-right" />
    </.link>
    """
  end

  defp lede([], []), do: "Desktop apps that report to Dokkit show here, one row each."

  defp lede(reported, silent) do
    attention = reported |> Enum.map(& &1.attention) |> Enum.sum()

    "#{plural(length(reported), "app reports", "apps report")} to Dokkit." <>
      if(attention > 0,
        do: " #{plural(attention, "thing needs", "things need")} a look.",
        else: " Nothing needs a look."
      ) <>
      if(silent != [], do: " #{plural(length(silent), "has", "have")} not reported yet.", else: "")
  end

  defp plural(1, one, _), do: "1 #{one}"
  defp plural(n, _, many), do: "#{n} #{many}"

  def render(assigns) do
    ~H"""
    <Layouts.app active={:apps} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">Apps</h1>
        <p class="lede">{lede(@reported, @silent)}</p>
      </div>
      
      <div class="body">
        <div class="card">
          <div :if={@reported == [] and @silent == []} class="empty">
            <.ic name="app-window" />No app has reported yet.
          </div>
          
          <div :if={@reported != []} class="lh cols-all ap">
            <span>Service</span><span>Version</span><span>Last reported</span><span>State</span><span>Attention</span><span></span>
          </div>
           <.rows rows={@reported} />
          <div :if={@silent != []} class="grp bare" id="no-signal">No signal yet</div>
           <.rows rows={@silent} />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
