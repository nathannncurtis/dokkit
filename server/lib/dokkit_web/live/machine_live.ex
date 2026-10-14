defmodule DokkitWeb.MachineLive do
  use DokkitWeb, :live_view
  alias Dokkit.{Alerts, Estate, Issue, Issues, Releases}
  alias DokkitWeb.{ChannelPick, MachineCards}

  @ranges [
    {"1", "The last 24 hours", 96},
    {"7", "The last 7 days", 168},
    {"30", "The last 30 days", 180}
  ]

  def mount(%{"id" => id}, _session, socket) do
    case Estate.machine(id) do
      %{kind: kind} = machine when kind in [:enrolled, :seen] ->
        {:ok,
         load(
           assign(socket,
             id: machine.id,
             page_title: machine.name,
             schedule: %{},
             schedule_error: nil,
             silent_saved: false,
             range: "7",
             procs_q: "",
             procs_sort: "memory",
             procs_all: false,
             procs_history: false
           )
         )}

      %{} ->
        {:ok, push_navigate(socket, to: ~p"/apps")}

      nil ->
        {:ok, push_navigate(socket, to: ~p"/all")}
    end
  end

  def handle_info(:issues_changed, socket),
    do: {:noreply, DokkitWeb.Auth.debounce(socket, :page, &load/1)}

  def handle_info({:settled, :page}, socket),
    do: {:noreply, DokkitWeb.Auth.settle(socket, :page, &load/1)}

  def handle_event("range", %{"range" => range}, socket) when range in ~w(1 7 30),
    do: {:noreply, load(assign(socket, range: range))}

  def handle_event("procs_filter", %{"q" => q}, socket),
    do: {:noreply, load(assign(socket, procs_q: String.slice(q, 0, 100)))}

  def handle_event("procs_sort", %{"sort" => sort}, socket) when sort in ~w(memory cpu),
    do: {:noreply, load(assign(socket, procs_sort: sort))}

  def handle_event("procs_all", _, socket),
    do: {:noreply, load(assign(socket, procs_all: !socket.assigns.procs_all))}

  def handle_event("procs_history", _, socket),
    do: {:noreply, load(assign(socket, procs_history: !socket.assigns.procs_history))}

  def handle_event("quiet_start", %{"quiet" => p}, socket) do
    DokkitWeb.QuietBand.start(socket, Map.put(p, "machine", socket.assigns.machine.id))
    {:noreply, load(socket)}
  end

  def handle_event("quiet_end", _, socket) do
    DokkitWeb.QuietBand.stop(socket, socket.assigns.machine.id)
    {:noreply, load(socket)}
  end

  def handle_event("schedule_form", %{"schedule" => p}, socket),
    do: {:noreply, assign(socket, schedule: p)}

  def handle_event("schedule_add", %{"schedule" => p}, socket) do
    case DokkitWeb.QuietBand.add_schedule(socket, socket.assigns.machine.id, p) do
      {:error, _, text} -> {:noreply, assign(load(socket), schedule: p, schedule_error: text)}
      _ -> {:noreply, assign(load(socket), schedule: %{}, schedule_error: nil)}
    end
  end

  def handle_event("schedule_remove", %{"id" => id}, socket) do
    DokkitWeb.QuietBand.remove_schedule(socket, socket.assigns.machine.id, id)
    {:noreply, load(socket)}
  end

  def handle_event("silent", %{"silent" => params}, socket) do
    machine = socket.assigns.machine
    saved = socket.assigns.current_user.role != :viewer

    if saved do
      params = Map.update(params, "down", [], &Alerts.exclusive(&1, machine.silent_route))
      Estate.set_silent(machine, params)
    end

    {:noreply, assign(load(socket), silent_saved: saved)}
  end

  def handle_event("update", _, socket) do
    held = Releases.newest()

    if socket.assigns.current_user.role == :owner and held,
      do: Releases.approve(held, socket.assigns.machine.id)

    {:noreply, load(socket)}
  end

  def handle_event("scan", _, socket) do
    if socket.assigns.current_user.role != :viewer,
      do: DokkitWeb.ApiController.look_again(socket.assigns.machine.id, "page")

    {:noreply, load(socket)}
  end

  defp load(socket) do
    now = DateTime.utc_now()
    machine = Estate.machine(socket.assigns.id)

    listed =
      Enum.find(Issues.machines(), &(&1.id == machine.id)) ||
        %{down: false, planned: nil, attention: 0}

    own = Estate.machine_service(machine.id)
    config = Alerts.config()
    held = Releases.newest()
    a = socket.assigns

    assign(socket,
      machine: machine,
      listed: listed,
      own: own,
      held: held,
      movable: Releases.movable?(machine, held),
      vitals: Dokkit.Numbers.vitals()[machine.id] || %{},
      history: history(own, machine, a.range, now),
      procs: processes(machine, a, now),
      services: services(machine),
      issues:
        for(
          i <- Issues.open_list(now) ++ Issues.snoozed_list(now),
          i.machine_id == machine.id,
          do: i
        ),
      schedules: Dokkit.QuietSchedules.lines(machine.id, now, config),
      zone: Dokkit.QuietSchedules.zone_label(config, now),
      defaults: config,
      routes: Alerts.channels(),
      scan: Dokkit.Found.scans()[machine.id],
      nudge: Dokkit.Work.last_nudge(machine.id)
    )
  end

  defp history(own, machine, range, now) do
    {_, _, points} = List.keyfind(@ranges, range, 0)
    from = DateTime.add(now, -String.to_integer(range) * 86_400)
    checks = (own && own.checks) || []

    for name <- Dokkit.Numbers.names({:machine, machine.id}) do
      check = Enum.find(checks, &(&1.name == name))
      open? = check != nil and check.state != :ok

      %{
        name: name,
        open: open?,
        note: open? && check.note,
        limit: check && Dokkit.Numbers.limit(check),
        points: Dokkit.Numbers.series({:machine, machine.id}, name, from, now, points)
      }
    end
    |> Enum.sort_by(&{!&1.open, !String.starts_with?(&1.name, "disk."), &1.name})
  end

  defp processes(machine, a, now) do
    list =
      Dokkit.Processes.list(machine, %{
        "q" => a.procs_q,
        "sort" => a.procs_sort,
        "limit" => if(a.procs_all, do: 10_000, else: 50)
      })

    recent =
      if a.procs_history,
        do:
          machine
          |> Dokkit.Processes.history(a.procs_sort, DateTime.add(now, -3600), now)
          |> Enum.reverse(),
        else: []

    %{list: list, history: recent}
  end

  defp services(machine) do
    watched = for s <- Estate.machine_services(machine.id), s.watched, do: s

    for {heading, states} <- [
          {"Needs a look", [:degraded, :down]},
          {"Fine", [:ok]},
          {"No signal yet", [:unknown]}
        ],
        list = Enum.filter(watched, &(&1.state in states)),
        list != [],
        do: {heading, list}
  end

  defp meters(vitals) do
    for {name, label} <-
          [{"cpu.percent", "Processor"}, {"memory.used_percent", "Memory"}] ++ disks(vitals),
        v = vitals[name],
        do: {label, v}
  end

  defp disks(vitals) do
    for "disk.used_percent." <> disk = name <- Enum.sort(Map.keys(vitals)),
        do: {name, "Disk #{disk}"}
  end

  defp since(issue), do: "#{Issue.short_id(issue)}, since #{at(issue.since)} UTC"

  defp nudge_state(:queued), do: "still queued"
  defp nudge_state(:running), do: "taken, no answer yet"
  defp nudge_state(:ok), do: "done"
  defp nudge_state(:fail), do: "failed"
  defp nudge_state(:refused), do: "refused"
  defp nudge_state(:expired), do: "expired, the machine never took it"

  defp snoozed?(issue),
    do:
      issue.snoozed_until != nil and
        DateTime.compare(issue.snoozed_until, DateTime.utc_now()) == :gt

  defp names(routes, value) do
    case Alerts.split(value) do
      [] ->
        "Nobody"

      list ->
        Enum.map_join(list, " and ", fn c ->
          Enum.find_value(routes, fn {t, v} -> v == c && t end)
        end)
    end
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        ranges: @ranges,
        down: assigns.listed.down,
        planned: assigns.listed.planned,
        attention: assigns.listed.attention
      )

    ~H"""
    <Layouts.app active={:all} shell={@shell} user={@current_user}>
      <div class="crumb">
        <.link navigate={~p"/all"}>Everything</.link><.ic name="caret-right" /><span>{@machine.name}</span>
      </div>
      
      <div class="head">
        <h1 tabindex="-1">
          <span
            :if={@planned && !@down}
            class="lvl away"
            role="img"
            aria-label="Planned downtime"
          ></span><.lvl
            :if={!@planned || @down}
            state={if @down, do: :down, else: if(@attention > 0, do: :degraded, else: :ok)}
          /> {@machine.name}
        </h1>
        
        <div class="end">
          <button
            :if={@machine.kind == :enrolled}
            class="btn"
            type="button"
            id="look-again"
            phx-click="scan"
            disabled={@current_user.role == :viewer}
          >
            <.ic name="binoculars" />Look again
          </button>
        </div>
      </div>
      
      <div class="filters" style="padding-top:10px">
        <span class={["tag", @down && "warn", !@down && "ok"]}>{if @down, do: "Down", else: "Up"}</span>
        <span class="st">
          {if @machine.last_seen_at,
            do: "Last reported #{at(@machine.last_seen_at)} UTC",
            else: "Has not reported yet"}
        </span>
         <span :if={@machine.os} class="st">{@machine.os}</span>
        <span class={["tag", @attention > 0 && "warn"]}>
          {if @attention == 0, do: "Nothing needs a look", else: "#{@attention} need a look"}
        </span>
        
        <span :if={@scan} class="st" role="status">{if @scan.state == :ok,
          do: "Looked at #{at(@scan.finished_at)} UTC.",
          else: DokkitWeb.FoundLive.scan_says(@scan)}</span>
      </div>
      
      <div class="body rail">
        <div class="col">
          <div class="card" id="meters">
            <h2>
              Now<span class="end">{if @vitals == %{},
                do: "No readings in the last 10 minutes",
                else: "Latest readings"}</span>
            </h2>
            
            <p :if={@vitals == %{}} class="lead">
              Processor, memory and disks appear here once the machine reports them.
            </p>
            
            <div
              :for={{label, v} <- meters(@vitals)}
              class="li slim"
              style="--cols: 120px minmax(0,1fr) auto"
            >
              <span>{label}</span>
              <span class={["vit", v >= 90 && "hot"]}><u style={"--v:#{round(v)}%"}><i></i></u></span>
              <span class="mono r">{round(v)}%<span :if={v >= 90}> high</span></span>
            </div>
          </div>
           <MachineCards.history history={@history} range={@range} ranges={@ranges} />
          <MachineCards.processes
            procs={@procs}
            procs_q={@procs_q}
            procs_sort={@procs_sort}
            procs_all={@procs_all}
            procs_history={@procs_history}
          />
          <div class="card" id="services">
            <h2>
              What runs on it<span class="end">{length(Enum.flat_map(@services, &elem(&1, 1)))} watched</span>
            </h2>
            
            <p :if={@services == []} class="lead">Nothing is being watched on this machine yet.</p>
            
            <%= for {heading, list} <- @services do %>
              <div class="grp bare">{heading}</div>
              
              <.link :for={s <- list} class="li slim cols-all pc" navigate={~p"/s/#{s.id}"}>
                <div class="ti"><.lvl state={s.state} /><span>{s.name}</span></div>
                 <span class="mono mute">{s.version}</span> <span class="mute">{kind(s.kind)}</span>
                <span class={["tag", s.state in [:degraded, :down] && "warn"]}>{s.note || say(s.state)}</span>
                <.ic name="caret-right" />
              </.link>
            <% end %>
            
            <div :if={@machine.kind == :enrolled} class="foot">
              <span>Things on it that are not watched are listed on Found.</span>
              <span class="end">
                <.link class="btn sm" navigate={~p"/found?#{[machine: @machine.name]}"}>
                  <.ic name="binoculars" />Open Found
                </.link>
              </span>
            </div>
          </div>
          
          <div class="card" id="downtime">
            <h2>Planned downtime</h2>
            
            <DokkitWeb.QuietBand.band
              machine={@machine.id}
              planned={@planned}
              control={true}
              disabled={@current_user.role == :viewer}
            />
            <DokkitWeb.QuietBand.schedules
              machine={@machine.id}
              schedules={@schedules}
              form={@schedule}
              error={@schedule_error}
              zone={@zone}
              disabled={@current_user.role == :viewer}
            />
          </div>
          
          <div class="card" id="issues">
            <h2>Open issues<span :if={@issues != []} class="cnt">{length(@issues)}</span></h2>
            
            <p :if={@issues == []} class="lead">Nothing is open on this machine.</p>
            
            <%= for i <- @issues do %>
              <.link
                :if={i.service_id}
                class="li slim"
                style="--cols: minmax(0,1fr) 16px"
                navigate={~p"/s/#{i.service_id}"}
              >
                <div>
                  <div class="ti">
                    <span class={["lvl", if(i.state == :down, do: "bad", else: "warn")]}></span><span>{i.title}</span>
                  </div>
                   <span class="st">{since(i)}{if snoozed?(i), do: ", snoozed"}</span>
                </div>
                 <.ic name="caret-right" />
              </.link>
              
              <div :if={!i.service_id} class="li slim" style="--cols: minmax(0,1fr)">
                <div>
                  <div class="ti">
                    <span class={["lvl", if(i.state == :down, do: "bad", else: "warn")]}></span><span>{i.title}</span>
                  </div>
                   <span class="st">{since(i)}{if snoozed?(i), do: ", snoozed"}</span>
                </div>
              </div>
            <% end %>
          </div>
        </div>
        
        <div class="col">
          <div class="card" id="versions">
            <h2>Program versions</h2>
            
            <dl class="kv">
              <dt>Program</dt>
              
              <dd class="mono">{@machine.program_version || "Unknown"}</dd>
              
              <dt>Updater</dt>
              
              <dd class="mono">
                {(@machine.has_updater && (@machine.updater_version || "Unknown")) || "None"}
              </dd>
              
              <dt :if={@machine.hosts_server}>Server</dt>
              
              <dd :if={@machine.hosts_server} class="mono">{@machine.server_version || "Unknown"}</dd>
              
              <dt :if={@machine.wanted_version}>Update pending</dt>
              
              <dd :if={@machine.wanted_version} class="mono">{@machine.wanted_version}</dd>
            </dl>
            
            <div :if={@nudge} class="foot" id="nudge">
              <span class={["st", @nudge.state in [:fail, :refused, :expired] && "warn"]}>
                Last update request {at(@nudge.asked_at)} UTC: {nudge_state(@nudge.state)}{if @nudge.answered_at,
                  do: ", answered " <> at(@nudge.answered_at) <> " UTC"}{if @nudge.output != "",
                  do: ". " <> String.trim(@nudge.output)}
              </span>
            </div>
            
            <div
              :if={Releases.outcome(@machine) || (@current_user.role == :owner and @movable)}
              class="foot"
              id="update"
            >
              <span
                :if={Releases.outcome(@machine)}
                class={["st", @machine.update_ok == false && "warn"]}
              >
                {Releases.outcome(@machine)}
              </span>
              
              <span class="end">
                <button
                  :if={@current_user.role == :owner and @movable}
                  class="btn sm"
                  type="button"
                  phx-click="update"
                >
                  Update to {@held}
                </button>
              </span>
            </div>
          </div>
          
          <form class="card" id="silent-form" phx-submit="silent">
            <h2>If this machine stops reporting</h2>
            
            <dl class="kv">
              <dt>Tell</dt>
              
              <dd>
                <ChannelPick.pick
                  name="silent[down]"
                  value={@machine.silent_route}
                  options={@routes}
                  label="Channels for this machine going quiet"
                  blank={"As set on Alerts (#{names(@routes, @defaults["down"])})"}
                  disabled={@current_user.role == :viewer}
                />
              </dd>
              
              <dt>At night</dt>
              
              <dd>
                <input type="hidden" name="silent[night]" value="false" />
                <label>
                  <input
                    type="checkbox"
                    name="silent[night]"
                    value="true"
                    checked={@machine.silent_wake}
                    disabled={@current_user.role == :viewer}
                  /> Wake me at night for this
                </label>
                
                <span class="hint">Off holds the alert until the night ends, if the machine is still quiet.</span>
              </dd>
            </dl>
            
            <div class="foot">
              <span :if={@silent_saved} role="status">Saved.</span>
              <span class="end">
                <button class="btn primary" type="submit" disabled={@current_user.role == :viewer}>
                  Save
                </button>
              </span>
            </div>
          </form>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
