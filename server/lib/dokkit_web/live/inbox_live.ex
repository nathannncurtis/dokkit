defmodule DokkitWeb.InboxLive do
  use DokkitWeb, :live_view
  alias Dokkit.{Found, Issue, Issues}

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

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ~w(now soon found snoozed),
    do: {:noreply, assign(socket, tab: String.to_existing_atom(tab), picked: MapSet.new())}

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

    assigns = assign(assigns, spans: @spans, tabs: @tabs, rows: rows(assigns), counts: counts)

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
      <div class="tabs" role="tablist">
        <button
          :for={{tab, label} <- @tabs}
          type="button"
          role="tab"
          aria-selected={to_string(@tab == tab)}
          class={@tab == tab && "on"}
          phx-click="tab"
          phx-value-tab={tab}
        >
          {label}<span :if={@counts[tab] > 0} class="cnt">{@counts[tab]}</span>
        </button>
      </div>
      <div class="body rail">
        <div class="card">
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
            />
            <span :if={@tab == :snoozed}></span>
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
              {if f.kind == "port", do: "Listening port", else: "Running service"}, {f.detail["saw"]}
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
        <div class="card">
          <h2>Estate</h2>
          <div :if={@shell.machines == []} class="empty">No machines yet.</div>
          <.link :for={m <- @shell.machines} class="est" navigate={~p"/all" <> "#m-#{m.id}"}>
            <b><span class={["lvl", m.state]}></span>{m.name}</b>
            <span class={["st", m.bad > 0 && "warn"]}>{estate(m)}</span>
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
    <details class="run" id={"issue-#{@i.id}"}>
      <summary class="li hov cols-inbox">
        <input
          :if={@tab in [:now, :soon]}
          class="chk"
          type="checkbox"
          checked={@i.id in @picked}
          phx-click="pick"
          phx-value-id={@i.id}
          aria-label="Select"
        />
        <span :if={@tab not in [:now, :soon]}></span>
        <div>
          <div class="ti"><.lvl state={@i.state} /><span>{@i.title}</span></div>
          <div class="meta">
            <span class="tag">{issue_kind(@i)}</span>
            <span class="mono">{Issue.short_id(@i)}</span>
            <span>Since {at(@i.since)} UTC</span>
            <span :if={@tab == :snoozed}>Back {at(@i.snoozed_until)} UTC</span>
            <span :if={@i.acknowledged_at} class="tag">Seen</span>
          </div>
        </div>
        <span></span>
        <div class="num">
          {@i.count}<small>{if @i.count == 1, do: "time", else: "times"}</small>
        </div>
        <span class="tag">{@i.machine.name}</span>
        <button
          :if={@tab == :snoozed}
          class="btn ghost"
          type="button"
          phx-click="back"
          phx-value-id={@i.id}
          aria-label="Bring back"
        >
          <.ic name="arrow-u-up-left" />
        </button>
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
        <span :if={@tab != :snoozed} class="end" style="display:flex; gap:6px; flex-wrap:wrap">
          <button
            :for={{{text, seconds}, n} <- Enum.with_index(@spans)}
            class={["btn sm", n > 0 && "ghost"]}
            type="button"
            phx-click="snooze"
            phx-value-id={@i.id}
            phx-value-span={seconds}
          >
            {if n == 0, do: "Snooze an hour", else: text}
          </button>
          <button class="btn sm" type="button" phx-click="seen" phx-value-id={@i.id}>
            Mark as seen
          </button>
        </span>
      </div>
    </details>
    """
  end

  defp fine(%{services: n, machines: m}) do
    "#{n} more #{if n == 1, do: "is", else: "are"} fine, on #{m} #{if m == 1, do: "machine", else: "machines"}."
  end

  defp told(%{status: :sent, channel: "page"}), do: "Paged"
  defp told(%{status: :sent, channel: "push"}), do: "Pushed"
  defp told(%{status: :sent, channel: "email"}), do: "Emailed"
  defp told(%{status: :sent, channel: "text"}), do: "Texted"
  defp told(%{status: :sent, channel: "webhook"}), do: "Webhook called"
  defp told(%{status: :failed}), do: "Alert not sent"
  defp told(_), do: nil

  defp where(%Issue{service_id: nil, machine_id: id}), do: ~p"/all" <> "#m-#{id}"
  defp where(%Issue{service_id: id}), do: ~p"/s/#{id}"

  defp issue_kind(%Issue{kind: "machine"}), do: "Machine"
  defp issue_kind(%Issue{kind: "job"}), do: "Job"
  defp issue_kind(_), do: "Check"

  defp estate(%{bad: 0, services: 0}), do: "nothing on it yet"
  defp estate(%{bad: 0}), do: "fine"
  defp estate(%{bad: 1}), do: "1 needs a look"
  defp estate(%{bad: n}), do: "#{n} need a look"
end
