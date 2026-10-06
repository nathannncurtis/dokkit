defmodule DokkitWeb.ServiceLive do
  use DokkitWeb, :live_view
  alias Dokkit.{Alerts, Estate, Issue, Issues}

  @cols "150px 110px 90px 90px minmax(0,1fr) 16px;--ncols:96px 72px 84px 56px minmax(0,1fr) 16px;--minw:426px"

  def mount(%{"id" => id}, _session, socket) do
    case Estate.service(id) do
      nil -> {:ok, push_navigate(socket, to: ~p"/all")}
      service -> {:ok, load(assign(socket, page_title: service.name, id: id))}
    end
  end

  def handle_info(:issues_changed, socket), do: {:noreply, load(socket)}

  def handle_event("route", %{"route" => params}, socket) do
    if socket.assigns.current_user.role != :viewer,
      do: Estate.set_routing(socket.assigns.service, params)

    {:noreply, load(socket)}
  end

  def handle_event(event, params, socket) when event in ~w(watching hold restart) do
    service = socket.assigns.service

    if socket.assigns.current_user.role != :viewer do
      case event do
        "watching" -> Estate.set_watched(service, !service.watched)
        "hold" -> Estate.set_hold(service, String.trim(params["version"] || ""))
        "restart" -> Estate.set_restart(service, !service.restart)
      end
    end

    {:noreply, load(socket)}
  end

  def handle_event(event, _, socket) when event in ~w(seen snooze back) do
    id = socket.assigns.issue && socket.assigns.issue.id

    if id && socket.assigns.current_user.role != :viewer do
      case event do
        "seen" -> Issues.acknowledge(id)
        "snooze" -> Issues.snooze(id, 86_400)
        "back" -> Issues.unsnooze(id)
      end
    end

    {:noreply, load(socket)}
  end

  defp snoozed?(issue),
    do:
      issue.snoozed_until != nil and
        DateTime.compare(issue.snoozed_until, DateTime.utc_now()) == :gt

  defp load(socket) do
    service = Estate.service(socket.assigns.id)
    job = Enum.find(service.checks, &(&1.type == :job))

    now = DateTime.utc_now()

    numbers =
      for name <- Dokkit.Numbers.names(socket.assigns.id) do
        points =
          Dokkit.Numbers.series(socket.assigns.id, name, DateTime.add(now, -86_400), now, 24)

        values = Enum.map(points, & &1.value)
        {name, values, values |> Enum.reject(&is_nil/1) |> List.last()}
      end

    socket = assign(socket, numbers: numbers)

    assign(socket,
      service: service,
      job: job,
      checks: Enum.reject(service.checks, &(&1.type == :job)),
      issue: Estate.open_issue(service),
      runs: Estate.runs(service),
      logs: Dokkit.Logs.list(service: service.id, limit: 20),
      defaults: Alerts.config()
    )
  end

  def render(assigns) do
    assigns = assign(assigns, cols: @cols, routes: Dokkit.Alerts.channels())

    ~H"""
    <Layouts.app active={:all} shell={@shell} user={@current_user}>
      <div class="crumb">
        <.link navigate={~p"/all"}>Everything</.link><.ic name="caret-right" /><span>{@service.machine.name}</span><.ic name="caret-right" /><span>{@service.name}</span>
      </div>
      <div class="head">
        <h1 tabindex="-1">
          <.lvl state={@service.state} /> {(@issue && @issue.title) || @service.name}
        </h1>
        <div class="end">
          <.link class="btn" navigate={~p"/logs?#{[s: @service.id]}"}><.ic name="scroll" />Logs</.link>
          <button :if={@issue && !@issue.acknowledged_at} class="btn" type="button" phx-click="seen">
            <.ic name="eye" />Mark as seen
          </button>
          <button :if={@issue && !snoozed?(@issue)} class="btn" type="button" phx-click="snooze">
            <.ic name="clock" />Snooze for a day
          </button>
          <button :if={@issue && snoozed?(@issue)} class="btn" type="button" phx-click="back">
            <.ic name="arrow-u-up-left" />Bring back
          </button>
        </div>
      </div>
      <div class="filters" style="padding-top:10px">
        <span class={[
          "tag",
          @service.state in [:degraded, :down] && "warn",
          @service.state == :ok && "ok"
        ]}>
          {say(@service.state)}
        </span>
        <span :if={@issue} class="st">
          <span class="mono">{Issue.short_id(@issue)}</span> since {at(@issue.since)} UTC
        </span>
        <span :if={@issue && snoozed?(@issue)} class="tag">Snoozed until {at(@issue.snoozed_until)} UTC</span>
        <span :if={@issue && @issue.acknowledged_at} class="tag">Seen</span>
      </div>
      <div class="body rail">
        <div class="col">
          <div :if={@job} class="card">
            <h2>Runs<span :if={@runs != []} class="end">Newest first</span></h2>
            <p :if={@runs == []} class="lead">No run seen yet.</p>
            <div :if={@runs != []} class="lh" style={"--cols:" <> @cols}>
              <span>Started</span><span>Result</span><span class="r">Took</span><span class="r">Exit code</span><span></span><span></span>
            </div>
            <details :for={r <- @runs} class="run" style={"--cols:" <> @cols} id={"run-#{r.id}"}>
              <summary class="li slim" style={"--cols:" <> @cols}>
                <span class="mono">{at(r.started_at || r.finished_at)}</span>
                <DokkitWeb.JobsLive.result run={r} />
                <span class="mono r">{took(r.duration_ms || between(r))}</span>
                <span class="mono r">{r.exit_code}</span>
                <span></span>
                <.ic name="caret-down" />
              </summary>
              <pre class="logbox">{r.tail || "No output was sent with this run."}</pre>
            </details>
          </div>
          <div :if={!@job or @checks != []} class="card">
            <h2>Checks</h2>
            <p :if={@checks == []} class="lead">No checks yet.</p>
            <div :for={c <- @checks} class="est">
              <b><.lvl state={c.state} />{c.name}</b>
              <span class="st">{c.note || say(c.state)}</span>
              <span class="mute" style="grid-column: 1 / -1">
                {target(c)}<span :if={c.checked_at}> · checked {at(c.checked_at)} UTC</span><span :if={
                  c.source == :file
                }> · from dokkit.toml</span>
              </span>
            </div>
          </div>
          <div :if={@numbers != []} class="card">
            <h2>Numbers<span class="end">The last 24 hours</span></h2>
            <div
              :for={{name, values, last} <- @numbers}
              class="li slim"
              style="--cols: minmax(0,1fr) 120px 90px"
            >
              <span class="mono">{name}</span>
              <.spark values={values} />
              <span class="mono r">{last && Float.round(last, 2)}</span>
            </div>
          </div>
          <div class="card">
            <h2>Latest logs</h2>
            <p :if={@logs == []} class="lead">
              No log lines from this {String.downcase(kind(@service.kind))} yet.
            </p>
            <pre :if={@logs != []} class="logbox"><%= for l <- Enum.reverse(@logs) do %><span>{at(l.at)}  <b :if={l.level in ~w(error fatal)}>{l.level}</b><em :if={l.level not in ~w(error fatal)}>{l.level}</em>  {l.msg}
    </span><% end %></pre>
          </div>
        </div>
        <div class="col">
          <div class="card">
            <h2>Details</h2>
            <dl class="kv">
              <dt>Machine</dt>
              <dd>{@service.machine.name}</dd>
              <dt>Kind</dt>
              <dd>{kind(@service.kind)}</dd>
              <dt :if={@job}>Schedule</dt>
              <dd :if={@job}>
                <span :if={@job.config["schedule"]} class="mono">{@job.config["schedule"]}</span>
                <span :if={!@job.config["schedule"]} class="mute">Not set</span>
              </dd>
              <dt :if={@job}>Last good run</dt>
              <dd :if={@job}><.time at={last_good(@runs)} none="None yet" /></dd>
              <dt :if={@job}>Next expected</dt>
              <dd :if={@job}><.time at={Estate.next_expected(@job)} none="Not scheduled" /></dd>
            </dl>
          </div>
          <div class="card">
            <h2>Watching</h2>
            <dl class="kv">
              <dt>{if @service.watched, do: "Watched", else: "Not watched"}</dt>
              <dd>
                <button class="btn sm" type="button" phx-click="watching">
                  {if @service.watched, do: "Stop watching", else: "Watch again"}
                </button>
                <span :if={!@service.watched} class="hint">Nothing it reports opens an issue.</span>
              </dd>
              <dt>Held version</dt>
              <dd>
                <form phx-submit="hold" id="hold-form" style="display: flex; gap: 8px">
                  <input
                    class="inp"
                    style="flex: 1 1 120px"
                    name="version"
                    value={@service.held}
                    placeholder="None"
                    aria-label="Version held on purpose"
                  />
                  <button class="btn sm" type="submit">Save</button>
                </form>
                <span class="hint">A version kept on purpose, so being behind is not news.</span>
              </dd>
              <dt :if={Enum.any?(@checks, &(&1.type == :"windows-service"))}>If it stops</dt>
              <dd :if={Enum.any?(@checks, &(&1.type == :"windows-service"))}>
                <button class="btn sm" type="button" phx-click="restart">
                  {if @service.restart, do: "Stop starting it again", else: "Start it again"}
                </button>
                <span class="hint">
                  {if @service.restart,
                    do: "The installed program starts it, at most once in ten minutes.",
                    else: "It is left stopped and you are told."}
                </span>
              </dd>
            </dl>
          </div>
          <form class="card" phx-change="route" id="route-form">
            <h2>Who hears about it</h2>
            <dl class="kv">
              <dt>{if @job, do: "If a run fails", else: "If it stops"}</dt>
              <dd>
                <.route
                  name="down"
                  value={@service.route_down}
                  routes={@routes}
                  default={@defaults["down"]}
                />
              </dd>
              <dt :if={!@job}>If it degrades</dt>
              <dd :if={!@job}>
                <.route
                  name="degraded"
                  value={@service.route_degraded}
                  routes={@routes}
                  default={@defaults["degraded"]}
                />
              </dd>
            </dl>
          </form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :at, :any, required: true
  attr :none, :string, required: true

  defp time(assigns) do
    ~H"""
    <span :if={@at} class="mono">{at(@at)} UTC</span><span :if={!@at} class="mute">{@none}</span>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :routes, :list, required: true
  attr :default, :string, required: true

  defp route(assigns) do
    ~H"""
    <span class="dd wide">
      <select class="inp" name={"route[#{@name}]"} aria-label="Channel">
        <option value="" selected={@value == nil}>
          As set on Alerts ({name(@routes, @default)})
        </option>
        <option :for={{text, value} <- @routes} value={value} selected={value == @value}>
          {text}
        </option>
      </select>
      <.ic name="caret-down" />
    </span>
    """
  end

  defp name(routes, value),
    do: Enum.find_value(routes, "Nobody", fn {text, v} -> v == value && text end)

  defp target(%{type: :http, config: %{"url" => url}}), do: "http " <> url

  defp target(%{type: :tcp, config: %{"port" => port} = c}),
    do: "tcp #{c["host"] || "localhost"}:#{port}"

  defp target(%{type: type, config: %{"name" => name}}), do: "#{type} #{name}"
  defp target(%{type: type}), do: to_string(type)

  defp last_good(runs), do: Enum.find_value(runs, &(&1.result == :ok && &1.finished_at))

  defp between(%{started_at: %DateTime{} = a, finished_at: %DateTime{} = b}),
    do: DateTime.diff(b, a, :millisecond)

  defp between(_), do: nil
end
