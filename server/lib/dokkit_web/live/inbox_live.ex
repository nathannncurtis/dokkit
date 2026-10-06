defmodule DokkitWeb.InboxLive do
  use DokkitWeb, :live_view
  alias Dokkit.{Found, Issue, Issues}
  alias Phoenix.LiveView.JS

  @spans [{"1 hour", 3600}, {"4 hours", 14_400}, {"1 day", 86_400}, {"1 week", 604_800}]
  @tabs [{:now, "Needs you"}, {:soon, "Soon"}, {:found, "Not watched"}, {:snoozed, "Snoozed"}]

  def mount(_params, _session, socket) do
    {:ok,
     load(assign(socket, page_title: "Inbox", tab: :now, picked: MapSet.new(), span: 86_400))}
  end

  def handle_info(:issues_changed, socket),
    do: {:noreply, DokkitWeb.Auth.debounce(socket, :page, &load/1)}

  def handle_info({:settled, :page}, socket),
    do: {:noreply, DokkitWeb.Auth.settle(socket, :page, &load/1)}

  def handle_params(params, _uri, socket) do
    tab =
      if params["tab"] in ~w(soon found snoozed),
        do: String.to_existing_atom(params["tab"]),
        else: :now

    {:noreply, assign(socket, tab: tab, picked: MapSet.new())}
  end

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ~w(now soon found snoozed),
    do: {:noreply, push_patch(socket, to: if(tab == "now", do: ~p"/", else: ~p"/?tab=#{tab}"))}

  def handle_event("pick", %{"id" => id}, socket) do
    picked = socket.assigns.picked
    picked = if id in picked, do: MapSet.delete(picked, id), else: MapSet.put(picked, id)
    {:noreply, assign(socket, picked: picked)}
  end

  def handle_event("pick_all", _, socket) do
    all = MapSet.new(rows(socket.assigns), & &1.id)
    picked = if MapSet.equal?(all, socket.assigns.picked), do: MapSet.new(), else: all
    {:noreply, assign(socket, picked: picked)}
  end

  def handle_event("span", %{"span" => span}, socket),
    do: {:noreply, assign(socket, span: String.to_integer(span))}

  def handle_event("snooze", params, socket) do
    ids = if params["id"], do: [params["id"]], else: MapSet.to_list(socket.assigns.picked)
    span = if params["span"], do: String.to_integer(params["span"]), else: socket.assigns.span
    act(socket, fn -> Issues.snooze(ids, span) end)
  end

  def handle_event("seen", %{"id" => id}, socket),
    do: act(socket, fn -> Issues.acknowledge(id) end)

  def handle_event("back", %{"id" => id}, socket), do: act(socket, fn -> Issues.unsnooze(id) end)
  def handle_event("watch", %{"id" => id}, socket), do: act(socket, fn -> Found.watch(id) end)
  def handle_event("leave", %{"id" => id}, socket), do: act(socket, fn -> Found.dismiss(id) end)

  defp act(socket, fun) do
    if socket.assigns.current_user.role != :viewer, do: fun.()
    {:noreply, load(assign(socket, picked: MapSet.new()))}
  end

  defp load(socket) do
    %{needs_you: now, soon: soon, other: other} = Issues.groups()

    assign(socket,
      now: now,
      soon: soon,
      other: other |> Enum.group_by(& &1.service.environment) |> Enum.sort(),
      found: Found.list(),
      snoozed: Issues.snoozed_list(),
      fine: Issues.fine(),
      day: Dokkit.Read.day(),
      linked: Enum.map(socket.assigns.shell.machines, & &1.id),
      picked: MapSet.intersection(socket.assigns.picked, MapSet.new(now ++ soon, & &1.id))
    )
  end

  defp rows(%{tab: :now, now: rows}), do: rows
  defp rows(%{tab: :soon, soon: rows}), do: rows
  defp rows(%{tab: :snoozed, snoozed: rows}), do: rows
  defp rows(_), do: []

  def render(assigns) do
    counts = %{
      now: length(assigns.now),
      soon: length(assigns.soon),
      found: length(assigns.found),
      snoozed: length(assigns.snoozed)
    }

    shell = %{assigns.shell | machines: with_counts(assigns.shell.machines, assigns)}

    assigns =
      assign(assigns,
        spans: @spans,
        tabs: @tabs,
        rows: rows(assigns),
        counts: counts,
        shell: shell
      )

    ~H"""
    <Layouts.app active={:inbox} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">Inbox</h1>

        <div class="end">
          <.link class="btn primary" navigate={~p"/jobs/new"}><.ic name="plus" />New job</.link>
        </div>
      </div>

      <div :if={@tab in [:now, :soon] and @rows != []} class="filters">
        <button class="btn" type="button" phx-click="snooze" disabled={MapSet.size(@picked) == 0}>
          <.ic name="clock" />Snooze selected
        </button>

        <form phx-change="span" id="span-form">
          <span class="dd">
            <select class="inp" name="span" aria-label="Snooze for">
              <option :for={{text, seconds} <- @spans} value={seconds} selected={seconds == @span}>
                for {text}
              </option>
            </select>
            <.ic name="caret-down" />
          </span>
        </form>
      </div>

      <div class="tabs" role="tablist" aria-label="Inbox sections">
        <button
          :for={{tab, label} <- @tabs}
          type="button"
          role="tab"
          id={"tab-#{tab}"}
          aria-controls="inbox-panel"
          aria-selected={to_string(@tab == tab)}
          class={@tab == tab && "on"}
          phx-click="tab"
          phx-value-tab={tab}
        >
          {label}<span :if={@counts[tab] > 0} class="cnt">{@counts[tab]}</span>
        </button>
      </div>

      <div class="body rail">
        <div class="card" id="inbox-panel" role="tabpanel" aria-labelledby={"tab-#{@tab}"}>
          <div :if={@rows == [] and @tab == :now} class="empty">
            <.ic name="check-circle" />Nothing here needs you. Everything else is fine.
          </div>

          <div :if={@rows == [] and @tab == :soon} class="empty">
            <.ic name="check-circle" />Nothing is about to need you.
          </div>

          <div :if={@found == [] and @tab == :found} class="empty">
            <.ic name="check-circle" />Nothing found is waiting for a decision.
          </div>

          <div :if={@rows == [] and @tab == :snoozed} class="empty">
            <.ic name="clock" />Nothing is snoozed.
          </div>

          <div :if={@rows != []} class="lh cols-inbox">
            <input
              :if={@tab != :snoozed}
              class="chk"
              type="checkbox"
              checked={MapSet.size(@picked) == length(@rows)}
              phx-click="pick_all"
              aria-label="Select all"
            /> <span :if={@tab == :snoozed}></span>
            <span>Issue</span><span></span><span class="r">Count</span><span>Machine</span><span></span>
          </div>
          <.issue_row :for={i <- @rows} i={i} tab={@tab} picked={@picked} spans={@spans} />
          <div :if={@tab == :found and @found != []} class="lh cols-inbox nw">
            <span>Found</span><span>How it was found</span><span>Machine</span><span></span>
          </div>

          <div
            :for={f <- if(@tab == :found, do: @found, else: [])}
            class="li hov cols-inbox nw"
            id={"found-#{f.id}"}
          >
            <div class="ti"><span class="lvl none"></span><span>{f.detail["label"]}</span></div>

            <span class="how">
              {how(f.kind)}, {f.detail["saw"]}
            </span>
            <span class="tag">{f.machine.name}</span>
            <div style="display:flex; gap:6px; justify-content:flex-end">
              <button class="btn sm primary" type="button" phx-click="watch" phx-value-id={f.id}>
                Watch it
              </button>

              <button class="btn sm" type="button" phx-click="leave" phx-value-id={f.id}>
                Leave it
              </button>
            </div>
          </div>

          <div :if={@tab == :now} class="foot">{fine(@fine)}</div>

          <div :for={{env, list} <- if(@tab == :now, do: @other, else: [])}>
            <div class="grp">
              {env}<span class="end"><span class="tag">{length(list)}</span></span>
            </div>
            <.issue_row :for={i <- list} i={i} tab={:other} picked={@picked} spans={@spans} />
          </div>
        </div>

        <div :if={@tab == :now} class="card wide" id="day">
          <h2>The last day<span class="end">UTC, now at the right</span></h2>

          <div class="day">
            <div :if={@day.machines == []} class="empty">No machines yet.</div>

            <div :if={@day.machines != []} class="lanes">
              <span></span>
              <div class="ticks" aria-hidden="true">
                <span
                  :for={{n, label} <- ticks(@day.from)}
                  style={"left: clamp(16px, #{Float.round((n + 0.5) / 48 * 100, 2)}%, calc(100% - 16px))"}
                >
                  {label}
                </span>
              </div>

              <div :for={m <- @day.machines} class="ln">
                <.link :if={m.id in @linked} navigate={~p"/all" <> "#m-#{m.id}"}>{m.name}</.link>
                <span :if={m.id not in @linked}>{m.name}</span>
                <div class="lane">
                  <i
                    :for={{c, n} <- Enum.with_index(m.cells)}
                    class={cell_class(c)}
                    role="img"
                    title={cell_title(m.name, @day.from, n, c)}
                    aria-label={cell_title(m.name, @day.from, n, c)}
                  ></i>
                </div>
              </div>
            </div>

            <div class="evs">
              <p :if={@day.events == []} class="mute">Nothing opened in the last day.</p>

              <p :for={e <- @day.events}>
                <b class="mono">{hm(e.at)}</b> {e.title} <span class="mute">{event_tail(e)}</span>
              </p>
            </div>
          </div>
        </div>

        <div class="card">
          <h2>Estate</h2>

          <div :if={@shell.machines == []} class="empty">No machines yet.</div>

          <.link :for={m <- @shell.machines} class="est" navigate={~p"/all" <> "#m-#{m.id}"}>
            <b><span class={["lvl", m.attention > 0 && "warn"]}></span>{m.name}</b>
            <span class={["st", m.attention > 0 && "warn"]}>{estate(m)}</span>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :i, :map, required: true
  attr :tab, :atom, required: true
  attr :picked, :any, required: true
  attr :spans, :list, required: true

  defp issue_row(assigns) do
    ~H"""
    <div class="irow" id={"issue-#{@i.id}"}>
      <input
        :if={@tab in [:now, :soon]}
        class="chk"
        type="checkbox"
        checked={@i.id in @picked}
        phx-click="pick"
        phx-value-id={@i.id}
        aria-label={"Select " <> @i.title}
      />
      <button
        :if={@tab == :snoozed}
        class="btn ghost bring"
        type="button"
        phx-click="back"
        phx-value-id={@i.id}
        aria-label={"Bring back " <> @i.title}
      >
        <.ic name="arrow-u-up-left" />
      </button>

      <details class="run" id={"issue-#{@i.id}-open"} phx-mounted={JS.ignore_attributes(["open"])}>
        <summary class="li hov cols-inbox">
          <span class="ck"></span>
          <div>
            <div class="ti">
              <span
                class={["lvl", if(@i.state == :down, do: "bad", else: "warn")]}
                role="img"
                aria-label={if @i.state == :down, do: "Down", else: "Needs a look"}
              ></span><span>{@i.title}</span>
            </div>

            <div class="meta">
              <span class="tag">{issue_kind(@i)}</span> <span class="mono">{Issue.short_id(@i)}</span>
              <span>Since {at(@i.since)} UTC</span>
              <span :if={@tab == :snoozed}>Back {at(@i.snoozed_until)} UTC</span>
              <span :if={@i.acknowledged_at} class="tag">Seen</span>
            </div>
          </div>
          <span></span>
          <div class="num">
            <span :if={@i.count > 1}>{@i.count}<small>times</small></span>
          </div>
          <span class="tag">{@i.machine.name}</span> <span :if={@tab == :snoozed}></span>
          <.ic :if={@tab != :snoozed} name="caret-down" />
        </summary>

        <div class="foot">
          <div style="flex-basis:100%">
            {(@i.check && @i.check.note) || "Dokkit has nothing more to say about this."}
          </div>

          <span
            :if={told(@i.alert)}
            class={["tag", @i.alert.status == :failed && "warn"]}
            title={@i.alert.error}
          >
            {told(@i.alert)}
          </span>
          <.link class="btn sm" navigate={where(@i)}>Open</.link>
          <span :if={@tab != :snoozed} class="end acts">
            <button
              class="btn sm primary"
              type="button"
              phx-click="snooze"
              phx-value-id={@i.id}
              phx-value-span={elem(hd(@spans), 1)}
            >
              Snooze an hour
            </button>

            <button class="btn sm" type="button" phx-click="seen" phx-value-id={@i.id}>
              Mark as seen
            </button>

            <span class="quiet" role="group" aria-label="Snooze for longer">
              <button
                :for={{text, seconds} <- tl(@spans)}
                class="btn sm ghost"
                type="button"
                phx-click="snooze"
                phx-value-id={@i.id}
                phx-value-span={seconds}
                aria-label={"Snooze for " <> text}
              >
                {text}
              </button>
            </span>
          </span>
        </div>
      </details>
    </div>
    """
  end

  defp hm(time), do: Calendar.strftime(time, "%H:%M")

  defp event_tail(e) do
    [
      "on " <> e.machine,
      e.sent && String.downcase(e.sent),
      e.closed_at && "closed itself " <> hm(e.closed_at)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  defp cell_class("down"), do: "bad"
  defp cell_class("degraded"), do: "warn"
  defp cell_class("none"), do: "none"
  defp cell_class(_), do: nil

  defp cell_title(name, from, n, cell) do
    say =
      %{
        "down" => "something was down",
        "degraded" => "something needed a look",
        "quiet" => "all quiet",
        "none" => "no signal"
      }[cell]

    "#{name} at #{hm(DateTime.add(from, n * 1800))}: #{say}"
  end

  defp fine(%{services: n, machines: m}) do
    "#{n} more #{if n == 1, do: "is", else: "are"} fine, on #{m} #{if m == 1, do: "machine", else: "machines"}."
  end

  defp how("port"), do: "Listening port"
  defp how("task"), do: "Scheduled task"
  defp how(_), do: "Running service"

  # An alert is sent once per issue, so there is no count; its update time is when it went.
  defp told(%{status: :sent, channel: channel, updated_at: at}) do
    verb = Dokkit.Alerts.sent_word(channel)
    verb && "#{verb} at #{DokkitWeb.Show.at(at)}"
  end

  defp told(%{status: :held}), do: "Held until #{Dokkit.Alerts.night_ends()}"
  defp told(%{status: :failed}), do: "Alert not sent"
  defp told(_), do: nil

  defp where(%Issue{service_id: nil, machine_id: id}), do: ~p"/all" <> "#m-#{id}"
  defp where(%Issue{service_id: id}), do: ~p"/s/#{id}"

  defp issue_kind(%Issue{kind: "machine"}), do: "Machine"
  defp issue_kind(%Issue{kind: "job"}), do: "Job"
  defp issue_kind(_), do: "Check"

  defp estate(%{attention: 1}), do: "1 needs a look"
  defp estate(%{attention: n}) when n > 1, do: "#{n} need a look"
  defp estate(%{soon: n}) when n > 0, do: "#{n} soon"
  defp estate(%{services: 0}), do: "nothing on it yet"
  defp estate(_), do: "fine"

  # Only what is under Needs you counts. Swap for Issues.attention_by_machine/0 when it exists.
  defp with_counts(machines, %{now: now, soon: soon}) do
    attention = Enum.frequencies_by(now, & &1.machine_id)
    soon = Enum.frequencies_by(soon, & &1.machine_id)

    for m <- machines,
        do: Map.merge(m, %{attention: attention[m.id] || 0, soon: soon[m.id] || 0})
  end

  defp ticks(from) do
    for n <- 0..47,
        t = DateTime.add(from, n * 1800),
        t.minute == 0 and t.hour in [0, 6, 12, 18],
        do: {n, hm(t)}
  end
end
