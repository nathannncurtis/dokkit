defmodule DokkitWeb.FoundLive do
  @moduledoc "Found: what a scan found on a machine, waiting to be watched or dismissed."
  use DokkitWeb, :live_view

  @sections [
    {"service", "Services", "gear-six"},
    {"port", "Ports", "plugs-connected"},
    {"job", "Scheduled jobs", "clock-countdown"},
    {"container", "Containers", "cube"},
    {"site", "Sites", "globe"}
  ]

  @origins [
    {"yours", "Yours", "set up by a person"},
    {nil, "Not sorted", "the machine did not say where it came from"},
    {"software", "Software", "installed by other software"},
    {"system", "System", "ships with the operating system"}
  ]

  @os %{"windows" => "Windows", "linux" => "Linux", "darwin" => "macOS"}
  @os_icon %{"windows" => "windows-logo", "linux" => "linux-logo", "darwin" => "apple-logo"}
  @short_section 8

  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         want: nil,
         keep: nil,
         selected: MapSet.new(),
         opened: %{},
         notes_open: false,
         more: MapSet.new()
       )}

  def handle_params(params, _uri, socket),
    do:
      {:noreply,
       load(
         assign(socket,
           page_title: "Found",
           system: params["system"] == "true",
           want: params["machine"]
         )
       )}

  def handle_info(:issues_changed, socket),
    do: {:noreply, DokkitWeb.Auth.debounce(socket, :page, &load/1)}

  def handle_info({:settled, :page}, socket),
    do: {:noreply, DokkitWeb.Auth.settle(socket, :page, &load/1)}

  def handle_event("sweep", %{"do" => what} = params, socket) do
    ids = params["ids"] || scope_ids(socket.assigns, params["scope"])

    case {socket.assigns.current_user.role, what} do
      {:viewer, _} -> nil
      {_, "watch"} -> Dokkit.Found.watch(ids)
      {_, "dismiss"} -> Dokkit.Found.dismiss(ids)
      _ -> nil
    end

    {:noreply, load(socket)}
  end

  def handle_event("system", params, socket),
    do:
      {:noreply,
       push_patch(socket, to: found_path(params["system"] == "true", socket.assigns.want))}

  def handle_event("scan", %{"id" => id}, socket) do
    if socket.assigns.current_user.role != :viewer,
      do: DokkitWeb.ApiController.look_again(id, "page")

    {:noreply, load(socket)}
  end

  def handle_event("pick", %{"id" => id}, socket),
    do: {:noreply, assign(socket, selected: flip(socket.assigns.selected, id))}

  def handle_event("pick_group", %{"kind" => kind, "origin" => origin}, socket) do
    ids = for f <- shown(socket.assigns), f.kind == kind, f.origin == origin_of(origin), do: f.id
    all? = ids != [] and Enum.all?(ids, &MapSet.member?(socket.assigns.selected, &1))
    set = MapSet.new(ids)

    selected =
      if all?,
        do: MapSet.difference(socket.assigns.selected, set),
        else: MapSet.union(socket.assigns.selected, set)

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("clear", _, socket), do: {:noreply, assign(socket, selected: MapSet.new())}

  def handle_event("open", %{"kind" => kind}, socket) do
    key = {socket.assigns.keep, kind}
    was = open?(socket.assigns.opened, socket.assigns.keep, kind, shown(socket.assigns))
    {:noreply, assign(socket, opened: Map.put(socket.assigns.opened, key, !was))}
  end

  def handle_event("notes", _, socket),
    do: {:noreply, assign(socket, notes_open: !socket.assigns.notes_open)}

  def handle_event("more", %{"id" => id}, socket),
    do: {:noreply, assign(socket, more: flip(socket.assigns.more, id))}

  defp flip(set, id),
    do: if(MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id))

  defp origin_of("none"), do: nil
  defp origin_of(o), do: o

  defp shown(%{current: nil}), do: []
  defp shown(%{current: stat}), do: stat.shown

  defp scope_ids(assigns, "selected"), do: MapSet.to_list(assigns.selected)

  defp scope_ids(assigns, scope) do
    rows = shown(assigns)

    if Enum.any?(@sections, &(elem(&1, 0) == scope)),
      do: for(f <- rows, f.kind == scope, do: f.id),
      else: for(f <- rows, f.id == scope, do: f.id)
  end

  defp open?(opened, name, kind, rows) do
    n = Enum.count(rows, &(&1.kind == kind))
    Map.get(opened, {name, kind}, n > 0 and n <= @short_section)
  end

  defp found_path(system, machine) do
    query = List.wrap(machine && {:machine, machine}) ++ if(system, do: [system: true], else: [])
    if query == [], do: ~p"/found", else: ~p"/found?#{query}"
  end

  defp load(socket) do
    system = socket.assigns.system
    by_machine = Dokkit.Found.list(system: true) |> Enum.group_by(& &1.machine_id)

    stats =
      for m <- Dokkit.Read.machines(), m.kind == :enrolled do
        all = Map.get(by_machine, m.id, [])
        {hidden, shown} = Enum.split_with(all, &(&1.origin == "system" and !system))

        %{
          machine: m,
          notes: all |> Enum.flat_map(&(&1.detail["limits"] || [])) |> Enum.uniq(),
          shown: Enum.sort_by(shown, &natural(&1.detail["label"])),
          hidden: length(hidden)
        }
      end
      |> Enum.sort_by(&String.downcase(&1.machine.name))

    named = fn name -> Enum.find(stats, &(&1.machine.name == name)) end
    chosen = named.(socket.assigns.want)

    current =
      chosen || named.(socket.assigns.keep) ||
        Enum.max_by(stats, &length(&1.shown), fn -> nil end)

    name = current && current.machine.name
    ids = MapSet.new(if(current, do: Enum.map(current.shown, & &1.id), else: []))
    same? = name == socket.assigns.keep

    assign(socket,
      stats: stats,
      current: current,
      keep: name,
      picked: chosen != nil,
      scale: Enum.max([1 | Enum.map(stats, &length(&1.shown))]),
      total: stats |> Enum.map(&length(&1.shown)) |> Enum.sum(),
      hidden: stats |> Enum.map(& &1.hidden) |> Enum.sum(),
      selected: MapSet.intersection(socket.assigns.selected, ids),
      notes_open: same? and socket.assigns.notes_open,
      more: if(same?, do: MapSet.intersection(socket.assigns.more, ids), else: MapSet.new()),
      scans: Dokkit.Found.scans()
    )
  end

  defp natural(label) do
    Regex.split(~r/(\d+)/, String.downcase(label), include_captures: true)
    |> Enum.map(&if(&1 =~ ~r/^\d+$/, do: String.to_integer(&1), else: &1))
  end

  defp count(rows, origin), do: Enum.count(rows, &(&1.origin == origin))

  defp summary(%{shown: [], hidden: 0}, _), do: ""

  defp summary(stat, system) do
    other = count(stat.shown, nil)

    (["#{count(stat.shown, "yours")} yours", "#{count(stat.shown, "software")} software"] ++
       if(other > 0, do: ["#{other} not sorted"], else: []) ++
       if(system,
         do: ["#{count(stat.shown, "system")} system"],
         else: ["#{stat.hidden} system hidden"]
       ))
    |> Enum.join(" · ")
  end

  defp breakdown(rows) do
    for(
      {o, label, _} <- @origins,
      n = count(rows, o),
      n > 0,
      do: "#{n} #{String.downcase(label)}"
    )
    |> Enum.join(", ")
  end

  defp meter(stat, scale) do
    parts = [
      count(stat.shown, "yours") + count(stat.shown, nil),
      count(stat.shown, "software"),
      count(stat.shown, "system")
    ]

    for n <- parts, do: n / scale * 100
  end

  defp has_more?(f), do: f.kind in ["job", "container"]

  defp group_state(rows, selected) do
    n = Enum.count(rows, &MapSet.member?(selected, &1.id))
    {n > 0 and n == length(rows), n > 0 and n < length(rows)}
  end

  defp job_how("task-scheduler"), do: "Scheduled task"
  defp job_how("systemd-timer"), do: "systemd timer"
  defp job_how("cron"), do: "Cron entry"
  defp job_how("launchd"), do: "launchd job"
  defp job_how(_), do: "Scheduled job"

  defp watched_from_record?(f), do: f.kind == "job" and f.detail["record"] == "record"

  defp run_line(slug, f),
    do: "dokkit run --job #{slug} -- #{f.detail["command"] || "<the command>"}"

  defp last_run(f) do
    [
      f.detail["last_run"] && "last run #{f.detail["last_run"]}",
      f.detail["last_result"] && "result #{f.detail["last_result"]}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  def scan_says(nil), do: nil
  def scan_says(%{state: :queued}), do: "Asked. Waiting for the machine to take it."
  def scan_says(%{state: :running}), do: "Looking now."

  def scan_says(%{state: :ok, finished_at: at}),
    do: "Looked at #{DokkitWeb.Show.at(at)} UTC. What it found is below."

  def scan_says(%{state: :fail, output: out}), do: "Could not look: " <> String.trim(out || "")

  def scan_says(%{state: :refused, output: out}) do
    if String.starts_with?(out || "", "This program does not run that"),
      do: "This machine's program is too old to be asked.",
      else: "The machine refused: " <> String.trim(out || "")
  end

  def render(assigns) do
    assigns = assign(assigns, viewer: assigns.current_user.role == :viewer, os: @os)

    ~H"""
    <Layouts.app active={:found} shell={@shell} user={@current_user}>
      <div class="fnd">
        <div class="head">
          <h1 tabindex="-1">
            Found<span :if={@stats != []} class="cnt" title="Waiting, all machines">{@total}</span>
          </h1>

          <form class="end" id="system-form" phx-change="system">
            <span class="tag">{if @system, do: "System shown", else: "#{@hidden} system hidden"}</span>
            <label class="mute" style="display: flex; align-items: center; gap: 8px">
              <input type="hidden" name="system" value="false" />
              <input type="checkbox" class="switch" name="system" value="true" checked={@system} />
              Show system services
            </label>
          </form>
        </div>

        <p class="lead">
          Pick a machine, then watch what is worth watching. Nothing is watched until you do.
        </p>

        <div :if={@stats == []} class="body">
          <div class="card" id="no-machines">
            <div class="empty"><.ic name="desktop" />No machine has joined yet.</div>
          </div>
        </div>

        <div :if={@stats != []} class={["fnd-grid", @picked && "picked"]}>
          <div class="card fnd-list">
            <h2>Machines<span class="cnt">{length(@stats)}</span></h2>

            <div
              class="fnd-sc"
              id="machine-list"
              role="listbox"
              aria-label="Machines"
              phx-hook="MachineKeys"
            >
              <.link
                :for={s <- @stats}
                patch={found_path(@system, s.machine.name)}
                id={"machine-#{s.machine.id}"}
                class="fnd-m"
                role="option"
                aria-selected={to_string(s == @current)}
                aria-current={to_string(s == @current)}
                tabindex={if s == @current, do: "0", else: "-1"}
              >
                <span class="ti"><span title={s.machine.name}>{s.machine.name}</span></span>
                <span class="cnt" title={"#{length(s.shown)} waiting"}>{length(s.shown)}</span>
                <span class="sub">
                  <span :if={s.machine.os}>{@os[s.machine.os] || s.machine.os}</span>
                  <span :if={s.hidden > 0}>{s.hidden} system hidden</span>
                </span>

                <div
                  class="seg3"
                  title={"#{count(s.shown, "yours")} yours, #{count(s.shown, "software")} software, #{count(s.shown, "system")} system"}
                >
                  <% [w, o, n] = meter(s, @scale) %> <i class="w" style={"width: #{w}%"}></i>
                  <i class="o" style={"width: #{o}%"}></i> <i class="n" style={"width: #{n}%"}></i>
                </div>
              </.link>
            </div>
          </div>

          <.panel
            :if={@current}
            stat={@current}
            system={@system}
            selected={@selected}
            opened={@opened}
            more={@more}
            notes_open={@notes_open}
            viewer={@viewer}
            scan={@scans[@current.machine.id]}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :stat, :map, required: true
  attr :system, :boolean, required: true
  attr :selected, :any, required: true
  attr :opened, :map, required: true
  attr :more, :any, required: true
  attr :notes_open, :boolean, required: true
  attr :viewer, :boolean, required: true
  attr :scan, :any, required: true

  defp panel(assigns) do
    m = assigns.stat.machine

    assigns =
      assign(assigns,
        m: m,
        notes: assigns.stat.notes,
        says: scan_says(assigns.scan),
        sections: @sections,
        origins: @origins,
        os: @os,
        os_icon: @os_icon,
        none: MapSet.size(assigns.selected) == 0
      )

    ~H"""
    <section class="card fnd-panel" id={"panel-#{@m.id}"} aria-label={@m.name <> " findings"}>
      <h2 tabindex="-1">
        <.link patch={found_path(@system, nil)} class="btn sm ghost fnd-back">
          <.ic name="caret-left" />Machines
        </.link>
        <.ic name={@os_icon[@m.os] || "desktop"} /> <span class="nm">{@m.name}</span>
        <span :if={@m.os} class="tag">{@os[@m.os] || @m.os}</span>
        <span class="sum">{summary(@stat, @system)}</span>
        <span class="end">
          <button
            class="btn sm"
            type="button"
            phx-click="notes"
            aria-expanded={to_string(@notes_open)}
            disabled={@notes == []}
          >
            <.ic name="note" />Scan notes<span class="cnt">{length(@notes)}</span>
          </button>

          <button
            class="btn sm"
            type="button"
            phx-click="scan"
            phx-value-id={@m.id}
            disabled={@viewer}
          >
            <.ic name="arrows-clockwise" />Look again
          </button>
        </span>
      </h2>

      <div :if={@says} class="fnd-says">{@says}</div>

      <div :if={@notes_open} class="fnd-notes">
        <p :for={n <- @notes} class="lead">{n}</p>
      </div>

      <div class="fnd-bar" role="toolbar" aria-label="Selection">
        <span class="sel">
          {if @none, do: "None selected", else: "#{MapSet.size(@selected)} selected"}
        </span>

        <button
          class="btn sm primary"
          type="button"
          phx-click="sweep"
          phx-value-do="watch"
          phx-value-scope="selected"
          disabled={@viewer or @none}
        >
          <.ic name="plus" />Watch selected
        </button>

        <button
          class="btn sm"
          type="button"
          phx-click="sweep"
          phx-value-do="dismiss"
          phx-value-scope="selected"
          disabled={@viewer or @none}
        >
          Dismiss selected
        </button>

        <button
          class="btn sm ghost"
          type="button"
          phx-click="clear"
          disabled={@none}
        >
          Clear
        </button>
      </div>

      <div class="fnd-sc" id={"findings-#{@m.id}"}>
        <div :if={@stat.shown == []} class="empty" id="panel-empty">
          <%= cond do %>
            <% @stat.hidden > 0 -> %>
              <.ic name="eye-slash" />{@stat.hidden} findings here are system ones, hidden.
              <button class="btn sm" type="button" phx-click="system" phx-value-system="true">
                Show system services
              </button>
            <% @scan == nil -> %>
              <.ic name="binoculars" />No scan has reported from {@m.name} yet. Look again asks it for one.
            <% true -> %>
              <.ic name="check-circle" />Nothing is waiting on {@m.name}. Whatever it found is watched or dismissed.
          <% end %>
        </div>

        <%= for {kind, title, icon} <- @sections, rows = Enum.filter(@stat.shown, &(&1.kind == kind)), rows != [] do %>
          <% open = open?(@opened, @m.name, kind, @stat.shown) %>
          <div class={["fnd-sec", open && "open"]} id={"sec-#{@m.id}-#{kind}"}>
            <div class="grp">
              <button
                class="btn ghost sm tg"
                type="button"
                phx-click="open"
                phx-value-kind={kind}
                aria-expanded={to_string(open)}
              >
                <i class="ph ph-caret-right caret" aria-hidden="true"></i><.ic name={icon} />{title}<span class="cnt">{length(
                  rows
                )}</span>
              </button>
              <span class="brk">{breakdown(rows)}</span>
              <span class="end">
                <button
                  class="btn sm primary"
                  type="button"
                  phx-click="sweep"
                  phx-value-do="watch"
                  phx-value-scope={kind}
                  disabled={@viewer}
                >
                  Watch all {length(rows)}
                </button>

                <button
                  class="btn sm"
                  type="button"
                  phx-click="sweep"
                  phx-value-do="dismiss"
                  phx-value-scope={kind}
                  disabled={@viewer}
                >
                  Dismiss all
                </button>
              </span>
            </div>

            <div :if={open}>
              <%= for {o, label, hint} <- @origins, part = Enum.filter(rows, &(&1.origin == o)), part != [] do %>
                <% {all?, some?} = group_state(part, @selected) %>
                <div class="lh sub fnd-lab" title={String.capitalize(hint)}>
                  <input
                    class="chk"
                    type="checkbox"
                    id={"grp-#{@m.id}-#{kind}-#{o || "none"}"}
                    phx-click="pick_group"
                    phx-value-kind={kind}
                    phx-value-origin={o || "none"}
                    phx-hook="Partial"
                    data-some={to_string(some?)}
                    checked={all?}
                    aria-label={"Select all #{String.downcase(label)} in #{title}"}
                  /> <span>{label}<span class="mute"> · {hint}</span></span>
                  <span class="cnt">{length(part)}</span>
                </div>

                <.found_row
                  :for={f <- part}
                  f={f}
                  selected={@selected}
                  more={@more}
                  viewer={@viewer}
                  icon={icon}
                />
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  attr :f, :map, required: true
  attr :selected, :any, required: true
  attr :more, :any, required: true
  attr :viewer, :boolean, required: true
  attr :icon, :string, required: true

  defp found_row(assigns) do
    ~H"""
    <div class="li slim fnd-row" id={"f-#{@f.id}"}>
      <input
        class="chk"
        type="checkbox"
        phx-click="pick"
        phx-value-id={@f.id}
        checked={MapSet.member?(@selected, @f.id)}
        aria-label={"Select " <> @f.detail["label"]}
      />
      <div>
        <div class="ti">
          <.ic name={@icon} /><span title={@f.detail["label"]}>{@f.detail["label"]}</span>
          <button
            :if={has_more?(@f)}
            class="btn ghost sm fnd-more-btn"
            type="button"
            phx-click="more"
            phx-value-id={@f.id}
            aria-expanded={to_string(MapSet.member?(@more, @f.id))}
            aria-label={"Details of " <> @f.detail["label"]}
            title="Details"
          >
            <.ic name={if MapSet.member?(@more, @f.id), do: "caret-up", else: "caret-down"} />
          </button>
        </div>

        <div class="mute sm-why" title={@f.why}>{@f.why}</div>
      </div>

      <div class="mute det" title={@f.detail["saw"]}>
        <div>{@f.detail["saw"]}</div>

        <div :if={@f.kind == "job" and last_run(@f) != ""} class="sub">{last_run(@f)}</div>
      </div>
      <span class="mute why" title={@f.why}>{@f.why}</span>
      <div class="act">
        <button
          class="btn sm primary"
          type="button"
          phx-click="sweep"
          phx-value-do="watch"
          phx-value-scope={@f.id}
          aria-label={"Watch " <> @f.detail["label"]}
          disabled={@viewer}
        >
          Watch
        </button>

        <button
          class="btn sm"
          type="button"
          phx-click="sweep"
          phx-value-do="dismiss"
          phx-value-scope={@f.id}
          aria-label={"Dismiss " <> @f.detail["label"]}
          disabled={@viewer}
        >
          <.ic name="x" /><span class="bl">Dismiss</span>
        </button>
      </div>
    </div>

    <div :if={has_more?(@f) and MapSet.member?(@more, @f.id)} class="lead fnd-more">
      <%= if @f.kind == "job" do %>
        <div :if={@f.detail["schedule"]}>
          {job_how(@f.detail["source"])}, schedule <code>{@f.detail["schedule"]}</code>
          (read as UTC). {@f.detail["schedule_note"]}
        </div>

        <div :if={!@f.detail["schedule"]}>
          No schedule Dokkit can read: {@f.detail["schedule_note"]} A run that fails is noticed; a run that does not happen is not.
        </div>

        <div :if={@f.detail["last_run"] || @f.detail["last_result"]}>
          Last run {@f.detail["last_run"] || "not recorded"}, result {@f.detail["last_result"] ||
            "not recorded"}.
        </div>

        <div :if={@f.detail["command"]}>
          It runs, for you to recognise it, not to be run by Dokkit:
          <code>{@f.detail["command"]}</code>
        </div>

        <div :if={watched_from_record?(@f)}>
          <strong>Watched from this machine's own record.</strong>
          Once watched, the program on this machine reads when it last ran and how it ended, and reports each new run. Nothing about the job changes.
          It waits for its next run before it can be judged.
        </div>

        <div :if={!watched_from_record?(@f)}>
          <strong>Needs the wrapper.</strong>
          Once watched, it waits for its first report. Wrap its command so each run is reported:
          <span class="once">
            <code class="mono" id={"wrap-#{@f.id}"}>{run_line(Dokkit.Found.slug(@f.key), @f)}</code>
            <button class="btn sm" type="button" data-copy={"#wrap-#{@f.id}"}>Copy</button>
          </span>
          or, from the end of the script,
          <span class="once">
            <code class="mono" id={"ping-#{@f.id}"}>dokkit ping {Dokkit.Found.slug(@f.key)} ok</code>
            <button class="btn sm" type="button" data-copy={"#ping-#{@f.id}"}>Copy</button>
          </span>
          (<code>fail</code>
          in place of <code>ok</code>
          when it failed).
        </div>
      <% else %>
        Checked by connecting to port {@f.detail["port"]} on this machine. A container that publishes no port cannot be checked, so it is not listed.
      <% end %>
    </div>
    """
  end
end
