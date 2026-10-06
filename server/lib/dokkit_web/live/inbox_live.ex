defmodule DokkitWeb.InboxLive do
  use DokkitWeb, :live_view
  alias Dokkit.{Issue, Issues}

  @spans [{"1 hour", 3600}, {"4 hours", 14_400}, {"1 day", 86_400}, {"1 week", 604_800}]

  def mount(_params, _session, socket) do
    {:ok,
     load(assign(socket, page_title: "Inbox", tab: :now, picked: MapSet.new(), span: 86_400))}
  end

  def handle_info(:issues_changed, socket), do: {:noreply, load(socket)}

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ~w(now snoozed),
    do: {:noreply, assign(socket, tab: String.to_existing_atom(tab))}

  def handle_event("pick", %{"id" => id}, socket) do
    picked = socket.assigns.picked
    picked = if id in picked, do: MapSet.delete(picked, id), else: MapSet.put(picked, id)
    {:noreply, assign(socket, picked: picked)}
  end

  def handle_event("pick_all", _, socket) do
    all = MapSet.new(socket.assigns.issues, & &1.id)
    picked = if MapSet.equal?(all, socket.assigns.picked), do: MapSet.new(), else: all
    {:noreply, assign(socket, picked: picked)}
  end

  def handle_event("span", %{"span" => span}, socket),
    do: {:noreply, assign(socket, span: String.to_integer(span))}

  def handle_event("snooze", params, socket) do
    ids = if params["id"], do: [params["id"]], else: MapSet.to_list(socket.assigns.picked)
    act(socket, fn -> Issues.snooze(ids, socket.assigns.span) end)
  end

  def handle_event("back", %{"id" => id}, socket), do: act(socket, fn -> Issues.unsnooze(id) end)

  defp act(socket, fun) do
    if socket.assigns.current_user.role != :viewer, do: fun.()
    {:noreply, load(assign(socket, picked: MapSet.new()))}
  end

  defp load(socket) do
    issues = Issues.open_list()
    picked = MapSet.intersection(socket.assigns.picked, MapSet.new(issues, & &1.id))
    assign(socket, issues: issues, snoozed: Issues.snoozed_list(), picked: picked)
  end

  def render(assigns) do
    rows = if assigns.tab == :now, do: assigns.issues, else: assigns.snoozed
    assigns = assign(assigns, spans: @spans, rows: rows)

    ~H"""
    <Layouts.app active={:inbox} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">Inbox</h1>
        <div class="end">
          <.link class="btn primary" navigate={~p"/jobs/new"}><.ic name="plus" />New job</.link>
        </div>
      </div>
      <div :if={@tab == :now and @issues != []} class="filters">
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
          type="button"
          role="tab"
          aria-selected={to_string(@tab == :now)}
          class={@tab == :now && "on"}
          phx-click="tab"
          phx-value-tab="now"
        >
          Needs you<span :if={@issues != []} class="cnt">{length(@issues)}</span>
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={to_string(@tab == :snoozed)}
          class={@tab == :snoozed && "on"}
          phx-click="tab"
          phx-value-tab="snoozed"
        >
          Snoozed<span :if={@snoozed != []} class="cnt">{length(@snoozed)}</span>
        </button>
      </div>
      <div class="body rail">
        <div class="card">
          <div :if={@rows == [] and @tab == :now} class="empty">
            <.ic name="check-circle" />Nothing needs you, and Dokkit will tell you when something does.
          </div>
          <div :if={@rows == [] and @tab == :snoozed} class="empty">
            <.ic name="clock" />Nothing is snoozed.
          </div>
          <div :if={@rows != []} class="lh cols-inbox">
            <input
              :if={@tab == :now}
              class="chk"
              type="checkbox"
              checked={MapSet.size(@picked) == length(@issues)}
              phx-click="pick_all"
              aria-label="Select all"
            />
            <span :if={@tab == :snoozed}></span>
            <span>Issue</span><span></span><span class="r">Count</span><span>Machine</span><span></span>
          </div>
          <div :for={i <- @rows} class="li hov cols-inbox" id={"issue-#{i.id}"}>
            <input
              :if={@tab == :now}
              class="chk"
              type="checkbox"
              checked={i.id in @picked}
              phx-click="pick"
              phx-value-id={i.id}
              aria-label="Select"
            />
            <span :if={@tab == :snoozed}></span>
            <div>
              <.link class="ti" navigate={where(i)}>
                <.lvl state={i.state} /><span>{i.title}</span>
              </.link>
              <div :if={i.check && i.check.note} class="sub">{i.check.note}</div>
              <div class="meta">
                <span class="tag">{issue_kind(i)}</span>
                <span class="mono">{Issue.short_id(i)}</span>
                <span>Since {at(i.since)} UTC</span>
                <span :if={@tab == :snoozed}>Back {at(i.snoozed_until)} UTC</span>
                <span :if={i.acknowledged_at} class="tag">Seen</span>
                <span
                  :if={told(i.alert)}
                  class={["tag", i.alert.status == :failed && "warn"]}
                  title={i.alert.error}
                >
                  {told(i.alert)}
                </span>
              </div>
            </div>
            <span></span>
            <div class="num">
              {i.count}<small>{if i.count == 1, do: "time", else: "times"}</small>
            </div>
            <span class="tag">{i.machine.name}</span>
            <div style="display:flex; gap:6px; justify-content:flex-end">
              <.link class="btn" navigate={where(i)}>Open</.link>
              <button
                :if={@tab == :now}
                class="btn ghost"
                type="button"
                phx-click="snooze"
                phx-value-id={i.id}
                aria-label="Snooze"
              >
                <.ic name="clock" />
              </button>
              <button
                :if={@tab == :snoozed}
                class="btn ghost"
                type="button"
                phx-click="back"
                phx-value-id={i.id}
                aria-label="Bring back"
              >
                <.ic name="arrow-u-up-left" />
              </button>
            </div>
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

  defp told(%{status: :sent, channel: "page"}), do: "Paged"
  defp told(%{status: :sent, channel: "push"}), do: "Pushed"
  defp told(%{status: :sent}), do: "Webhook called"
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
