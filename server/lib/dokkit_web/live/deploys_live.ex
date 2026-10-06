defmodule DokkitWeb.DeploysLive do
  use DokkitWeb, :live_view

  @cols "minmax(0,1.2fr) minmax(0,1.2fr) 120px 110px 140px 16px"

  def mount(_params, _session, socket), do: {:ok, load(assign(socket, page_title: "Deploys"))}

  def handle_info(:issues_changed, socket), do: {:noreply, load(socket)}

  defp load(socket), do: assign(socket, deploys: Dokkit.Deploys.list())

  def render(assigns) do
    assigns = assign(assigns, cols: @cols)

    ~H"""
    <Layouts.app active={:deploys} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">Deploys</h1>
      </div>
      <div class="body">
        <div class="card">
          <div :if={@deploys == []} class="empty">
            <.ic name="rocket-launch" />No deploy seen yet. One is recorded when a service's version changes.
          </div>
          <div :if={@deploys != []} class="lh cols-dep" style={"--cols:" <> @cols}>
            <span>Service</span><span>Version</span><span>Machine</span><span>When</span><span>How it was seen</span><span></span>
          </div>
          <.link
            :for={d <- @deploys}
            class="li slim cols-dep"
            style={"--cols:" <> @cols}
            navigate={~p"/s/#{d.service_id}"}
          >
            <div class="ti"><span>{d.service.name}</span></div>
            <span class="mono" style="display:flex; flex-wrap:wrap; align-items:center; gap:6px">
              {d.from}<.ic name="arrow-right" />{d.version}
            </span>
            <span class="tag">{d.service.machine.name}</span>
            <span class="mono">{at(d.at)}</span>
            <span class="tag">
              {if d.how == "reported",
                do: "Reported" <> if(d.by, do: " by #{d.by}", else: ""),
                else: "Noticed by Dokkit"}
            </span>
            <.ic name="caret-right" />
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
