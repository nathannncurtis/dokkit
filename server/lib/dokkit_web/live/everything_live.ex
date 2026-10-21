defmodule DokkitWeb.EverythingLive do
  use DokkitWeb, :live_view
  alias Dokkit.Estate

  def mount(_params, _session, socket),
    do:
      {:ok,
       load(assign(socket, page_title: "Everything", dep_open: false, dep_error: nil, dep: %{}))}

  def handle_info(:issues_changed, socket),
    do: {:noreply, DokkitWeb.Auth.debounce(socket, :page, &load/1)}

  def handle_info({:settled, :page}, socket),
    do: {:noreply, DokkitWeb.Auth.settle(socket, :page, &load/1)}

  def handle_event("dep_open", _, socket),
    do: {:noreply, assign(socket, dep_open: !socket.assigns.dep_open, dep_error: nil)}

  def handle_event("dependency", %{"dep" => p}, socket) do
    target = String.trim(p["target"] || "")

    check =
      case p["type"] do
        "http" -> %{"type" => "http", "url" => target}
        "tcp" -> %{"type" => "tcp", "address" => target}
        _ -> nil
      end

    with true <- socket.assigns.current_user.role == :owner,
         {:ok, id} <-
           Estate.add_dependency(%{
             "name" => p["name"],
             "machine" => p["machine"],
             "check" => check
           }) do
      {:noreply, push_navigate(socket, to: ~p"/s/#{id}")}
    else
      false -> {:noreply, assign(socket, dep: p, dep_error: "An owner adds dependencies.")}
      {:error, why} -> {:noreply, assign(socket, dep: p, dep_error: why)}
    end
  end

  def handle_event("update", %{"machine" => id}, socket),
    do: owner(socket, fn held -> Dokkit.Releases.approve(held, id) end)

  def handle_event("update_all", _, socket),
    do: owner(socket, fn held -> Dokkit.Releases.approve(held, :all) end)

  def handle_event("dismiss_update", _, socket) do
    Dokkit.UpdateRun.dismiss()
    {:noreply, socket}
  end

  def handle_event("quiet_start", %{"quiet" => p}, socket) do
    DokkitWeb.QuietBand.start(socket, p)
    {:noreply, load(socket)}
  end

  def handle_event("quiet_end", %{"machine" => id}, socket) do
    DokkitWeb.QuietBand.stop(socket, id)
    {:noreply, load(socket)}
  end

  defp owner(socket, act) do
    held = Dokkit.Releases.newest()
    if socket.assigns.current_user.role == :owner and held, do: act.(held)
    {:noreply, load(socket)}
  end

  defp load(socket) do
    listed = Dokkit.Issues.machines()
    down = for m <- listed, m.down, do: m.id
    machines = Estate.machines()
    held = Dokkit.Releases.newest()

    assign(socket,
      machines: machines,
      down: down,
      planned: for(m <- listed, m.planned, into: %{}, do: {m.id, m.planned}),
      vitals: Dokkit.Numbers.vitals(),
      held: held,
      movable: Enum.count(machines, &Dokkit.Releases.movable?(&1, held))
    )
  end

  # No updater: only a Windows machine is told how to get one.
  defp windows?(m),
    do: m.kind == :enrolled and String.contains?(String.downcase(m.os || ""), "windows")

  defp lede(machines, down) do
    machines = Enum.filter(machines, &(&1.kind != :group))
    watched = for m <- machines, s <- m.services, s.slug != "machine", s.watched, do: s

    head =
      "#{plural(length(watched), "thing", "things")} watched on #{plural(length(machines), "machine", "machines")}, in one place."

    case length(down) do
      0 -> head <> " None of the machines is down."
      n -> head <> " #{plural(n, "machine is", "machines are")} down."
    end
  end

  defp plural(1, one, _), do: "1 #{one}"
  defp plural(n, _, many), do: "#{n} #{many}"

  def render(assigns) do
    ~H"""
    <Layouts.app active={:all} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">Everything</h1>
        
        <p class="lede">{lede(@machines, @down)}</p>
        
        <div class="end">
          <button
            :if={@current_user.role == :owner and @movable > 1}
            class="btn"
            type="button"
            id="update-all"
            phx-click="update_all"
          >
            <.ic name="arrow-circle-up" />Update all to {@held}
          </button>
          
          <.link class="btn" navigate={~p"/machines/new"}><.ic name="hard-drives" />Add a machine</.link>
          <button
            class="btn"
            type="button"
            id="add-dependency"
            phx-click="dep_open"
            aria-expanded={to_string(@dep_open)}
          >
            <.ic name="plugs" />Add a dependency
          </button>
           <.link class="btn primary" navigate={~p"/jobs/new"}><.ic name="plus" />New job</.link>
        </div>
      </div>
      
      <div class="body">
        <div :if={@shell.failed != []} class="notice" id="update-failed" role="status">
          <b><.ic name="warning" />{failed_title(@shell.failed)}</b>
          <span class="end">
            <button class="btn sm" type="button" phx-click="dismiss_update">Dismiss</button>
          </span>
          
          <ul>
            <li :for={m <- @shell.failed}>
              <.link navigate={~p"/machines/#{m.id}"}>{m.name}</.link>: {m.note}
            </li>
          </ul>
        </div>
        
        <form :if={@dep_open} class="card" id="dependency-form" phx-submit="dependency">
          <h2>Add a dependency</h2>
          
          <dl class="kv">
            <dt>Name</dt>
            
            <dd>
              <input
                class="inp"
                style="flex: 1 1 260px"
                name="dep[name]"
                value={@dep["name"]}
                placeholder="Payment gateway"
                required
                aria-label="Name"
              />
            </dd>
            
            <dt>Checked from</dt>
            
            <dd>
              <select class="inp" name="dep[machine]" aria-label="Checked from">
                <option value="">No check yet (kept under Outside)</option>
                
                <option
                  :for={m <- @machines}
                  :if={m.kind == :enrolled}
                  value={m.name}
                  selected={@dep["machine"] == m.name}
                >
                  {m.name}
                </option>
              </select>
               <span class="hint">The machine whose dokkit runs the check.</span>
            </dd>
            
            <dt>Check</dt>
            
            <dd>
              <select class="inp" name="dep[type]" aria-label="Check type">
                <option value="">None</option>
                
                <option value="http" selected={@dep["type"] == "http"}>Web address</option>
                
                <option value="tcp" selected={@dep["type"] == "tcp"}>Port</option>
              </select>
              
              <input
                class="inp mono"
                style="flex: 1 1 260px"
                name="dep[target]"
                value={@dep["target"]}
                placeholder="https://pay.example.com/health, or host:443"
                aria-label="Address"
              />
            </dd>
          </dl>
          
          <div class="foot">
            <span :if={@dep_error} class="bad" role="alert">{@dep_error}</span>
            <span :if={@current_user.role != :owner} class="hint">An owner adds dependencies.</span>
            <span class="end">
              <button class="btn primary" type="submit" disabled={@current_user.role != :owner}>Add the dependency</button>
            </span>
          </div>
        </form>
        
        <div class="card">
          <div :if={@machines == []} class="empty">
            <.ic name="squares-four" />Nothing is being watched yet. Add a job to start.
          </div>
          
          <div :if={@machines != []} class="lh cols-all">
            <span>Service</span><span>Version</span><span>Listens</span><span>Kind</span><span></span><span>State</span><span></span>
          </div>
          
          <%= for m <- @machines do %>
            <div class="mg" role="group" aria-labelledby={"mh-#{m.id}"}>
              <div class="grp" id={"m-#{m.id}"}>
                <span id={"mh-#{m.id}"} style="display:flex; align-items:center; gap:8px"><span
                  :if={@planned[m.id] && m.id not in @down}
                  class="lvl away"
                  role="img"
                  aria-label="Planned downtime"
                ></span><.lvl
                  :if={!@planned[m.id] || m.id in @down}
                  state={if m.id in @down, do: :down, else: worst(m.services)}
                /><.link navigate={home(m)}>{m.name}</.link></span>
                <span :if={m.os} class="mute" style="font-weight:400">{m.os}</span>
                <span class="end">
                  <span :if={@planned[m.id]} class="tag">Planned downtime until {Calendar.strftime(
                    @planned[m.id].until,
                    "%H:%M"
                  )} UTC</span>
                  <span :if={m.id in @down} class="tag warn">Stopped reporting {at(m.last_seen_at)} UTC</span>
                  <span :if={count(m.services, :bad) > 0} class="tag warn">{need(
                    count(m.services, :bad)
                  )}</span>
                  <span :if={count(m.services, :ok) > 0} class="tag">{count(m.services, :ok)} fine</span>
                  <span :if={@vitals[m.id]} class="vits">
                    <span
                      :for={{name, label} <- [{"cpu.percent", "cpu"}, {"memory.used_percent", "mem"}]}
                      :if={v = @vitals[m.id][name]}
                      class={["vit", v >= 90 && "hot"]}
                    >
                      {label} <u style={"--v:#{round(v)}%"}><i></i></u> {round(v)}%
                    </span>
                  </span>
                </span>
              </div>
              
              <DokkitWeb.QuietBand.band
                machine={m.id}
                planned={@planned[m.id]}
                disabled={@current_user.role == :viewer}
              />
              <div :if={m.has_updater} class="foot" id={"upd-#{m.id}"}>
                <span class="mono">
                  Program {m.program_version || "unknown"}{m.hosts_server &&
                    " / Server #{m.server_version || "unknown"}"}
                </span>
                
                <span :if={Dokkit.Releases.outcome(m)} class={["st", m.update_ok == false && "warn"]}>{Dokkit.Releases.outcome(
                  m
                )}</span>
                <span class="end">
                  <button
                    :if={@current_user.role == :owner and Dokkit.Releases.movable?(m, @held)}
                    class="btn sm"
                    type="button"
                    phx-click="update"
                    phx-value-machine={m.id}
                  >
                    Update to {@held}
                  </button>
                </span>
              </div>
              
              <div :if={!m.has_updater and windows?(m)} class="foot" id={"upd-#{m.id}"}>
                <span>No updater on this machine. On it, from an administrator prompt:
                <code>dokkit updater install</code></span>
              </div>
              
              <div :if={m.services == []} class="kid-none">
                Nothing is running on this machine yet.
              </div>
              
              <.link :for={s <- m.services} class="li slim kid cols-all" navigate={~p"/s/#{s.id}"}>
                <div class="ti"><.lvl state={s.state} /><span>{s.name}</span></div>
                 <span class="mono mute">{s.version}</span> <span class="mono mute">{s.listens}</span>
                <span class="mute">{kind(s.kind)}</span> <span></span>
                <span class={["tag", s.state in [:degraded, :down] && "warn"]}>{(!s.watched &&
                                                                                   "Not watched") ||
                  s.note || say(s.state)}</span> <.ic name="caret-right" />
              </.link>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp home(%{kind: :group}), do: ~p"/apps"
  defp home(m), do: ~p"/machines/#{m.id}"

  defp failed_title([_]), do: "1 machine did not update"
  defp failed_title(list), do: "#{length(list)} machines did not update"

  defp count(services, :bad), do: Enum.count(services, &(&1.state in [:degraded, :down]))
  defp count(services, :ok), do: Enum.count(services, &(&1.state == :ok))

  defp worst(services),
    do:
      if(count(services, :bad) > 0, do: :down, else: if(services == [], do: :unknown, else: :ok))

  defp need(1), do: "1 needs a look"
  defp need(n), do: "#{n} need a look"
end
