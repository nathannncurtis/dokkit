defmodule DokkitWeb.DeploysLive do
  use DokkitWeb, :live_view

  @cols "minmax(0,1.2fr) minmax(0,1.2fr) 200px 110px 140px 16px"

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_params(_params, _uri, socket) do
    title = if socket.assigns.live_action == :versions, do: "Versions", else: "Deploys"
    {:noreply, load(assign(socket, page_title: title))}
  end

  def handle_info(:issues_changed, socket),
    do: {:noreply, DokkitWeb.Auth.debounce(socket, :page, &load/1)}

  def handle_info({:settled, :page}, socket),
    do: {:noreply, DokkitWeb.Auth.settle(socket, :page, &load/1)}

  defp load(socket) do
    machines = Enum.filter(Dokkit.Estate.machines(), &(&1.kind != :group))

    services =
      for m <- machines, s <- m.services, s.version, reduce: %{} do
        acc -> Map.update(acc, {s.slug, s.name}, %{m.id => s}, &Map.put(&1, m.id, s))
      end

    program = for m <- machines, m.program_version, into: %{}, do: {m.id, m.program_version}

    rows =
      if(program == %{}, do: [], else: [{"dokkit", program, nil}]) ++
        for {{_, name}, on} <- Enum.sort(services) do
          {name, Map.new(on, fn {id, s} -> {id, s.version} end), on |> Map.values() |> hd()}
        end

    assign(socket,
      deploys: Dokkit.Deploys.list(),
      apps: Dokkit.Deploys.apps(),
      machines: machines,
      rows: rows
    )
  end

  # Versions are compared by their numbers, so 2.10 is newer than 2.9.
  defp newest(on) do
    on |> Map.values() |> Enum.max_by(&Dokkit.Deploys.number/1)
  end

  def render(assigns) do
    assigns = assign(assigns, cols: @cols)

    ~H"""
    <Layouts.app active={@live_action} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">{@page_title}</h1>
      </div>
      
      <div :if={@live_action == :versions} class="body">
        <div class="card">
          <h2>Services<span class="end">Which version is on which machine</span></h2>
          
          <div :if={@rows == []} class="empty">
            <.ic name="git-branch" />No service has reported a version yet.
          </div>
          
          <div :if={@rows != []} class="scroll">
            <table class="vt">
              <thead>
                <tr>
                  <th scope="col">Service</th>
                  
                  <th :for={m <- @machines} scope="col">{m.name}</th>
                  
                  <th></th>
                </tr>
              </thead>
              
              <tbody>
                <tr :for={{name, on, service} <- @rows} class={!service && "flat"}>
                  <th scope="row">
                    <.link :if={service} navigate={~p"/s/#{service.id}"}>{name}</.link>
                    <span :if={!service}>{name}</span>
                  </th>
                  
                  <td :for={m <- @machines}>
                    <span :if={on[m.id] && on[m.id] != newest(on)} class="tag warn">{on[m.id]}</span>
                    <span :if={on[m.id] == newest(on)}>{on[m.id]}</span>
                  </td>
                  
                  <td><.ic :if={service} name="caret-right" /></td>
                </tr>
              </tbody>
            </table>
          </div>
          
          <div :if={@rows != []} class="foot">
            <span class="tag warn">Behind the newest</span><span>Empty: not installed there</span>
          </div>
        </div>
      </div>
      
      <div :if={@live_action == :versions and @apps != []} class="body" style="padding-top: 0">
        <div class="card">
          <h2>Desktop apps<span class="end">Which version is on how many machines</span></h2>
          
          <div :for={a <- @apps} id={"app-#{a.service.id}"}>
            <.link
              class="li slim"
              style="--cols: minmax(0,1fr) auto 16px"
              navigate={~p"/s/#{a.service.id}"}
            >
              <div class="ti"><span>{a.service.name}</span></div>
               <span class="st">{a.hosts} {if a.hosts == 1, do: "machine", else: "machines"}</span>
              <.ic name="caret-right" />
            </.link>
            
            <div
              :for={{{version, hosts}, n} <- Enum.with_index(a.versions)}
              class="li slim"
              style="--cols: 120px 60px minmax(0,1fr)"
            >
              <span class={["tag", n > 0 && "warn"]}>{version}</span>
              <span class="st">{length(hosts)}</span>
              <span class="mute">{if n > 0, do: Enum.join(Enum.sort(hosts), ", "), else: "The newest"}</span>
            </div>
          </div>
        </div>
      </div>
      
      <div :if={@live_action == :deploys} class="body">
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
             <span class="tag" title={d.service.machine.name}>{d.service.machine.name}</span>
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
