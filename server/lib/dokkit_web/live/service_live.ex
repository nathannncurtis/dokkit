defmodule DokkitWeb.ServiceLive do
  use DokkitWeb, :live_view
  alias Dokkit.{Alerts, AppUpdates, Estate, Issue, Issues}
  alias DokkitWeb.{ChannelPick, WhoPick}
  alias Phoenix.LiveView.JS

  @cols "150px 110px 90px 90px minmax(0,1fr) 16px;--ncols:96px 72px 84px 56px minmax(0,1fr) 16px;--minw:426px"

  def mount(%{"id" => id}, _session, socket) do
    case Estate.service(id) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/all")}

      service ->
        {:ok,
         load(
           assign(socket,
             page_title: service.name,
             id: id,
             timing_error: nil,
             timing: %{},
             app_error: nil
           )
         )}
    end
  end

  def handle_info(:issues_changed, socket),
    do: {:noreply, DokkitWeb.Auth.debounce(socket, :page, &load/1)}

  def handle_info({:settled, :page}, socket),
    do: {:noreply, DokkitWeb.Auth.settle(socket, :page, &load/1)}

  def handle_event("timing_typed", %{"timing" => params}, socket),
    do: {:noreply, assign(socket, timing: params)}

  def handle_event("timing", %{"timing" => params}, socket) do
    error =
      with true <- socket.assigns.current_user.role != :viewer,
           job when job != nil <- socket.assigns.job,
           {:error, text} <- Estate.set_job_timing(job, params) do
        text
      else
        _ -> nil
      end

    {:noreply,
     assign(load(socket), timing_error: error, timing: if(error, do: params, else: %{}))}
  end

  def handle_event("route", %{"route" => params}, socket) do
    service = socket.assigns.service

    params =
      for {k, v} <- params, into: %{} do
        if k in ~w(down degraded) and is_list(v),
          do: {k, Alerts.exclusive(v, Map.get(service, :"route_#{k}"))},
          else: {k, v}
      end

    if socket.assigns.current_user.role != :viewer, do: Estate.set_routing(service, params)

    {:noreply, load(socket)}
  end

  def handle_event("who", %{"who" => params}, socket) do
    if socket.assigns.current_user.role == :owner, do: WhoPick.save(params)
    {:noreply, load(socket)}
  end

  def handle_event(event, params, socket)
      when event in ~w(watching hold restart messages deployer) do
    service = socket.assigns.service

    role = socket.assigns.current_user.role

    if role != :viewer and (event not in ~w(restart deployer) or role == :owner) do
      case event do
        "watching" -> Estate.set_watched(service, !service.watched)
        "hold" -> Estate.set(service, :held, String.trim(params["version"] || ""))
        "restart" -> Estate.set(service, :restart, !service.restart)
        "messages" -> Estate.set(service, :keep_messages, !service.keep_messages)
        "deployer" -> Estate.set(service, :deployer, !service.deployer)
      end
    end

    {:noreply, load(socket)}
  end

  def handle_event("app_save", %{"app" => p}, socket),
    do:
      owner_app(
        socket,
        &AppUpdates.save(&1, Map.take(p, ~w(repo mode hold require_signature signer assets)))
      )

  def handle_event("app_reset", %{"field" => field}, socket),
    do: owner_app(socket, &AppUpdates.save(&1, %{field => nil}))

  def handle_event("app_update", %{"machine" => id}, socket),
    do: owner_app(socket, &AppUpdates.approve(&1, id))

  def handle_event("app_update_all", _, socket),
    do: owner_app(socket, &AppUpdates.approve(&1, :all))

  def handle_event("app_fetch", _, socket), do: owner_app(socket, &AppUpdates.fetch/1)

  def handle_event("app_token", %{"token" => token}, socket),
    do: owner_app(socket, fn _ -> AppUpdates.save_token(token) end)

  def handle_event("quiet_end", _, socket) do
    DokkitWeb.QuietBand.stop(socket, socket.assigns.service.machine_id)
    {:noreply, load(socket)}
  end

  def handle_event("note", %{"text" => text}, socket) do
    issue = socket.assigns.issue

    if issue && String.trim(text) != "" && socket.assigns.current_user.role != :viewer,
      do: Issues.note(issue.id, String.trim(text), socket.assigns.current_user.name)

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

  defp owner_app(socket, act) do
    result =
      if socket.assigns.current_user.role == :owner,
        do: act.(socket.assigns.service.slug),
        else: {:error, "owner", "An owner changes app updates."}

    error =
      case result do
        {:error, _, why} -> why
        _ -> nil
      end

    {:noreply, assign(load(socket), app_error: error)}
  end

  defp updatable?(service), do: service.kind in [:service, :app] and service.slug != "machine"

  defp checked(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, t, _} -> at(t)
      _ -> iso
    end
  end

  defp app_state(%{state: "installing", wanted: v}), do: "Installing #{v}"
  defp app_state(%{state: "waiting", wanted: v}), do: "Asked to move to #{v}"
  defp app_state(%{state: "failed", result_version: v}), do: "Update to #{v} failed"
  defp app_state(%{state: "done", result_version: v}), do: "Updated to #{v}"
  defp app_state(%{behind: true}), do: "Behind"
  defp app_state(_), do: "Current"

  attr :updates, :map, required: true
  attr :field, :string, required: true
  attr :words, :string, required: true
  attr :user, :map, required: true

  defp app_default(assigns) do
    ~H"""
    <span class="hint">
      Default: {@words}
      <button
        :if={@field in @updates.changed and @user.role == :owner}
        class="btn sm"
        type="button"
        phx-click="app_reset"
        phx-value-field={@field}
      >
        Reset
      </button>
    </span>
    """
  end

  defp machine_path(%{kind: :group}), do: ~p"/apps"
  defp machine_path(machine), do: ~p"/machines/#{machine.id}"

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

    assign(socket,
      numbers: numbers,
      service: service,
      job: job,
      planned: Enum.find(Dokkit.Quiet.active(now), &(&1.machine_id == service.machine_id)),
      checks: Enum.reject(service.checks, &(&1.type == :job)),
      issue: Estate.open_issue(service),
      runs: Estate.runs(service),
      logs: Dokkit.Logs.list(service: service.id, limit: 20),
      defaults: Alerts.config(),
      people: Dokkit.People.list(),
      who: Dokkit.People.audience_rows(),
      updates: if(updatable?(service), do: AppUpdates.view(service.slug)),
      token: AppUpdates.token_view()
    )
  end

  defp lede(:down, %{since: since}), do: "Something is wrong here, since #{at(since)} UTC."

  defp lede(:degraded, %{since: since}),
    do: "Working, but not as it should, since #{at(since)} UTC."

  defp lede(:ok, _), do: "Fine. Nothing here needs a look."
  defp lede(state, _) when state in [:down, :degraded], do: "Something here needs a look."
  defp lede(_, _), do: "No signal yet. It shows here once it reports."

  def render(assigns) do
    assigns = assign(assigns, cols: @cols, routes: Dokkit.Alerts.channels())

    ~H"""
    <Layouts.app active={:all} shell={@shell} user={@current_user}>
      <div class="crumb">
        <.link navigate={~p"/all"}>Everything</.link><.ic name="caret-right" /><.link navigate={
          machine_path(@service.machine)
        }>{@service.machine.name}</.link><.ic name="caret-right" /><span>{@service.name}</span>
      </div>

      <div class="head">
        <h1 tabindex="-1">
          <.lvl state={@service.state} /> {(@issue && @issue.title) || @service.name}
        </h1>

        <p class="lede">{lede(@service.state, @issue)}</p>

        <div class="end">
          <.link
            :if={@service.slug == "machine"}
            class="btn"
            id="machine-page"
            navigate={machine_path(@service.machine)}
          >
            <.ic name="desktop" />{@service.machine.name}
          </.link>

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
          <div :if={@planned && @service.slug != "machine"} class="card" id="downtime">
            <DokkitWeb.QuietBand.band
              machine={@service.machine_id}
              planned={@planned}
              disabled={@current_user.role == :viewer}
            />
          </div>

          <div :if={@issue && @issue.processes} class="card" id="at-the-time">
            <h2>
              At the time<span class="end">{String.slice(@issue.processes["at"], 0, 16)
              |> String.replace("T", " ")} UTC</span>
            </h2>

            <div class="li slim" style="--cols: 90px minmax(0,1fr)">
              <span class="mute">Most memory</span>
              <span class="mono">{DokkitWeb.MachineCards.top_line(
                @issue.processes["top_memory"],
                "memory",
                5
              )}</span>
            </div>

            <div class="li slim" style="--cols: 90px minmax(0,1fr)">
              <span class="mute">Most processor</span>
              <span class="mono">{DokkitWeb.MachineCards.top_line(
                @issue.processes["top_cpu"],
                "cpu",
                5
              )}</span>
            </div>
          </div>

          <div :if={@issue} class="card">
            <h2>Notes<span :if={@issue.notes != []} class="cnt">{length(@issue.notes)}</span></h2>

            <div :for={n <- @issue.notes} class="li slim" style="--cols: minmax(0,1fr) auto">
              <span>{n["text"]}</span>
              <span class="st">{n["by"]}, {String.slice(to_string(n["at"]), 0, 16)
              |> String.replace("T", " ")} UTC</span>
            </div>

            <form phx-submit="note" id="note-form" style="display: flex; gap: 8px; padding: 10px 14px">
              <input
                class="inp"
                style="flex: 1 1 260px"
                name="text"
                placeholder="What you found or did"
                aria-label="Add a note to this issue"
                autocomplete="off"
              /> <button class="btn sm" type="submit">Add</button>
            </form>
          </div>

          <div :if={@job} class="card">
            <h2>Runs<span :if={@runs != []} class="end">Newest first</span></h2>

            <p :if={@runs == []} class="lead">No run seen yet.</p>

            <div :if={@runs != []} class="lh" style={"--cols:" <> @cols}>
              <span>Started</span><span>Result</span><span class="r">Took</span><span class="r">Exit code</span><span></span><span></span>
            </div>

            <details
              :for={r <- @runs}
              class="run"
              style={"--cols:" <> @cols}
              id={"run-#{r.id}"}
              phx-mounted={JS.ignore_attributes(["open"])}
            >
              <summary class="li slim" style={"--cols:" <> @cols}>
                <span class="mono">{at(r.started_at || r.finished_at)}</span>
                <DokkitWeb.JobsLive.result run={r} />
                <span class="mono r">{took(r.duration_ms || between(r))}</span>
                <span class="mono r">{r.exit_code}</span>
                <span><DokkitWeb.JobsLive.progress run={r} /></span> <.ic name="caret-down" />
              </summary>
              <pre class="logbox">{r.tail || "No output was sent with this run."}</pre>
            </details>
          </div>

          <div :if={!@job or @checks != []} class="card">
            <h2>Checks</h2>

            <p :if={@checks == []} class="lead">No checks yet.</p>

            <div :for={c <- @checks} class="est">
              <b><.lvl state={c.state} />{c.name}</b> <span class="st">{c.note || say(c.state)}</span>
              <span class="mute" style="grid-column: 1 / -1">
                {target(c)}<span :if={c.checked_at}> · checked {at(c.checked_at)} UTC</span><span :if={
                  c.source == :file
                }> · from dokkit.toml</span>
              </span>

              <span style="grid-column: 1 / -1">
                <WhoPick.pick
                  scope="check"
                  id={c.id}
                  people={@people}
                  who={@who}
                  above="Told as the service says."
                  disabled={@current_user.role != :owner}
                />
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
              <span class="mono">{name}</span> <.spark values={values} />
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

            <form
              :if={@job && @job.source == :reported}
              phx-change="timing_typed"
              phx-submit="timing"
              id="timing-form"
            >
              <dl class="kv">
                <dt>Count it as late after</dt>

                <dd>
                  <input
                    class="inp mono"
                    style="width: 120px"
                    name="timing[grace]"
                    value={Map.get(@timing, "grace", @job.config["grace"])}
                    placeholder="30m"
                    aria-label="Count it as late after"
                  />
                </dd>

                <dt>Say it ran long after</dt>

                <dd>
                  <input
                    class="inp mono"
                    style="width: 120px"
                    name="timing[max_runtime]"
                    value={Map.get(@timing, "max_runtime", @job.config["max_runtime"])}
                    placeholder="1h"
                    aria-label="Say it ran long after"
                  />
                </dd>
              </dl>

              <div class="foot">
                <span :if={@timing_error} class="bad" role="alert">{@timing_error}</span>
                <span class="end"><button class="btn sm" type="submit">Save</button></span>
              </div>
            </form>

            <dl :if={@job && @job.source == :file} class="kv">
              <dt>Count it as late after</dt>

              <dd class="mono">{@job.config["grace"] || "30m"}</dd>

              <dt>Say it ran long after</dt>

              <dd class="mono">{@job.config["max_runtime"] || "Not set"}</dd>

              <dt></dt>

              <dd class="mute">Set in its dokkit.toml.</dd>
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
                <form
                  phx-submit="hold"
                  id="hold-form"
                  style="display: flex; gap: 8px; flex: 1 1 100%; min-width: 0"
                >
                  <input
                    class="inp"
                    style="flex: 1 1 120px"
                    name="version"
                    value={@service.held}
                    placeholder="None"
                    aria-label="Version held on purpose"
                  /> <button class="btn sm" type="submit">Save</button>
                </form>
                <span class="hint">A version kept on purpose, so being behind is not news.</span>
              </dd>

              <dt>Error messages</dt>

              <dd>
                <button class="btn sm" type="button" phx-click="messages">
                  {if @service.keep_messages, do: "Stop keeping them", else: "Keep them"}
                </button>

                <span class="hint">
                  {if @service.keep_messages,
                    do: "The text of each error is stored with it.",
                    else:
                      "Only the type and the stack are stored. Messages are where personal data ends up."}
                </span>
              </dd>

              <dt :if={@service.kind == :app}>Deploys other apps</dt>

              <dd :if={@service.kind == :app}>
                <button
                  class="btn sm"
                  type="button"
                  phx-click="deployer"
                  disabled={@current_user.role != :owner}
                >
                  {if @service.deployer, do: "Stop letting it", else: "Let it"}
                </button>

                <span class="hint">
                  {if @service.deployer,
                    do: "Its key records a deploy for each app it installs on a machine.",
                    else:
                      "For an app that installs the others. Its key can then record their deploys."}
                </span>
              </dd>

              <dt :if={Enum.any?(@checks, &(&1.type in [:"windows-service", :systemd]))}>
                If it stops
              </dt>

              <dd :if={Enum.any?(@checks, &(&1.type in [:"windows-service", :systemd]))}>
                <button
                  class="btn sm"
                  type="button"
                  phx-click="restart"
                  disabled={@current_user.role != :owner}
                >
                  {if @service.restart, do: "Stop starting it again", else: "Start it again"}
                </button>

                <span class="hint">
                  {if @service.restart,
                    do: "The installed program starts it, at most once in ten minutes.",
                    else: "It is left stopped and you are told."} {if @current_user.role != :owner,
                    do: "An owner changes this."}
                </span>
              </dd>
            </dl>
          </div>

          <div :if={@updates} class="card" id="updates">
            <h2>
              Updates<span :if={@updates.url} class="end"><a
                href={@updates.url}
                target="_blank"
                rel="noopener noreferrer"
              >{@updates.repo}</a></span>
            </h2>

            <form phx-submit="app_save" id="app-update-form">
              <dl class="kv">
                <dt>GitHub repository</dt>

                <dd>
                  <input
                    class="inp mono"
                    style="flex: 1 1 220px"
                    name="app[repo]"
                    value={@updates.repo}
                    placeholder="owner/name"
                    aria-label="GitHub repository"
                    disabled={@current_user.role != :owner}
                  />
                  <.app_default updates={@updates} field="repo" words="None" user={@current_user} />
                </dd>

                <dt>Mode</dt>

                <dd>
                  <select
                    class="inp"
                    name="app[mode]"
                    aria-label="Update mode"
                    disabled={@current_user.role != :owner}
                  >
                    <option value="click" selected={@updates.mode == "click"}>Click to update</option>
                    <option value="automatic" selected={@updates.mode == "automatic"}>
                      Automatic
                    </option>
                  </select>
                  <span class="hint">
                    Automatic installs a release once it is fetched and checked, one machine at a time, and stops at the first failure.
                  </span>
                  <.app_default
                    updates={@updates}
                    field="mode"
                    words="Click to update"
                    user={@current_user}
                  />
                </dd>

                <dt>Hold</dt>

                <dd>
                  <input type="hidden" name="app[hold]" value="false" />
                  <label>
                    <input
                      type="checkbox"
                      name="app[hold]"
                      value="true"
                      checked={@updates.hold}
                      disabled={@current_user.role != :owner}
                    /> Hold every update of this app
                  </label>
                  <.app_default updates={@updates} field="hold" words="Off" user={@current_user} />
                </dd>

                <dt>Signed installer</dt>

                <dd>
                  <input type="hidden" name="app[require_signature]" value="false" />
                  <label>
                    <input
                      type="checkbox"
                      name="app[require_signature]"
                      value="true"
                      checked={@updates.require_signature}
                      disabled={@current_user.role != :owner}
                    /> Require a signed installer
                  </label>
                  <span class="hint">
                    On Windows, an .exe or .msi must carry a valid Authenticode signature, from the signer below when one is named. Off, only its SHA-256 is checked.
                  </span>
                  <.app_default
                    updates={@updates}
                    field="require_signature"
                    words="On"
                    user={@current_user}
                  />
                </dd>

                <dt>Signer</dt>

                <dd>
                  <input
                    class="inp"
                    style="flex: 1 1 220px"
                    name="app[signer]"
                    value={@updates.signer}
                    placeholder="Example Software Ltd"
                    aria-label="Signer"
                    disabled={@current_user.role != :owner}
                  />
                  <span class="hint">
                    The Authenticode signer a signed installer must come from. Empty takes any valid signature.
                  </span>
                  <.app_default updates={@updates} field="signer" words="None" user={@current_user} />
                </dd>

                <dt>Release files</dt>

                <dd>
                  <textarea
                    class="inp mono"
                    style="height:auto; padding:8px 10px; flex: 1 1 100%; resize:vertical"
                    name="app[assets]"
                    rows="3"
                    spellcheck="false"
                    placeholder="windows/amd64 acme-intake-*-windows-amd64.zip"
                    aria-label="Release files"
                    disabled={@current_user.role != :owner}
                  >{Enum.map_join(@updates.assets, "\n", fn {k, v} -> "#{k} #{v}" end)}</textarea>
                  <span class="hint">
                    One line for each system and processor: the release file to install there, where * is any text. A machine's dokkit.toml can name its own with asset.
                  </span>
                  <.app_default updates={@updates} field="assets" words="None" user={@current_user} />
                </dd>

                <dt></dt>

                <dd>
                  <button class="btn sm" type="submit" disabled={@current_user.role != :owner}>
                    Save
                  </button>
                  <span :if={@app_error} class="bad" role="alert">{@app_error}</span>
                  <span :if={@current_user.role != :owner} class="hint">An owner changes these.</span>
                </dd>
              </dl>
            </form>

            <dl class="kv">
              <dt>GitHub token</dt>

              <dd>
                <form
                  phx-submit="app_token"
                  id="github-token-form"
                  style="display: flex; gap: 8px; flex: 1 1 100%; min-width: 0"
                >
                  <input
                    class="inp mono"
                    style="flex: 1 1 200px"
                    type="password"
                    name="token"
                    autocomplete="off"
                    placeholder={
                      if @token.github_token == "set",
                        do: "Set, ending #{@token.ending}",
                        else: "Not set"
                    }
                    aria-label="GitHub read token"
                    disabled={@current_user.role != :owner}
                  />
                  <button class="btn sm" type="submit" disabled={@current_user.role != :owner}>
                    Save
                  </button>
                </form>
                <span class="hint">
                  One read token for every app's releases, kept on this server and never shown again. Saving it empty clears it. Public repositories need none.
                </span>
              </dd>

              <dt>Newest release</dt>

              <dd>
                <a
                  :if={@updates.newest && @updates.newest.url}
                  href={@updates.newest.url}
                  class="mono"
                  target="_blank"
                  rel="noopener noreferrer"
                >{@updates.newest.version}</a>
                <span :if={@updates.newest && !@updates.newest.url} class="mono">
                  {@updates.newest.version}
                </span>
                <span :if={!@updates.newest} class="mute">None held yet.</span>
                <span :for={f <- (@updates.newest && @updates.newest.files) || []} class="tag mono">
                  {f.name} {String.slice(f.sha256 || "", 0, 12)}
                </span>
                <span :if={@updates.check_note} class="st warn">{@updates.check_note}</span>
                <span :if={@updates.checked_at} class="hint">
                  Looked at GitHub {checked(@updates.checked_at)} UTC.
                </span>
                <button
                  :if={@current_user.role == :owner and @updates.repo != ""}
                  class="btn sm"
                  type="button"
                  phx-click="app_fetch"
                >
                  Look now
                </button>
              </dd>

              <%= for m <- @updates.machines do %>
                <dt><.link navigate={~p"/machines/#{m.id}"}>{m.name}</.link></dt>

                <dd id={"app-machine-#{m.id}"}>
                  <span class="mono">{m.version || "Version unknown"}</span>
                  <span class={["tag", m.state == "failed" && "warn", m.state == "done" && "ok"]}>
                    {app_state(m)}
                  </span>
                  <span :if={m.note && m.state in ["done", "failed"]} class="st">{m.note}</span>
                  <button
                    :if={@current_user.role == :owner and m.can_update and !@updates.hold}
                    class="btn sm"
                    type="button"
                    phx-click="app_update"
                    phx-value-machine={m.id}
                  >
                    Update to {@updates.newest.version}
                  </button>
                  <span :if={m.behind and m.why} class="hint">{m.why}</span>
                </dd>
              <% end %>

              <dt :if={@updates.machines == []}>Machines</dt>

              <dd :if={@updates.machines == []} class="mute">
                No machine installs it yet. The Dokkit updater on a monitored machine installs it once that machine's dokkit.toml has an [app] table.
              </dd>
            </dl>

            <div
              :if={
                @current_user.role == :owner and !@updates.hold and
                  Enum.count(@updates.machines, & &1.can_update) > 1
              }
              class="foot"
            >
              <span class="end">
                <button class="btn sm" type="button" phx-click="app_update_all" id="app-update-all">
                  Update all to {@updates.newest.version}
                </button>
              </span>
            </div>
          </div>

          <div class="card">
            <h2>Who hears about it</h2>

            <form phx-change="route" id="route-form">
              <dl class="kv">
                <dt>{if @job, do: "If a run fails", else: "If it stops"}</dt>

                <dd>
                  <ChannelPick.pick
                    name="route[down]"
                    value={@service.route_down}
                    options={@routes}
                    label={if @job, do: "If a run fails", else: "If it stops"}
                    blank={"As set on Alerts (#{names(@routes, @defaults["down"])})"}
                  />
                </dd>

                <dt :if={!@job}>If it degrades</dt>

                <dd :if={!@job}>
                  <ChannelPick.pick
                    name="route[degraded]"
                    value={@service.route_degraded}
                    options={@routes}
                    label="If it degrades"
                    blank={"As set on Alerts (#{names(@routes, @defaults["degraded"])})"}
                  />
                </dd>

                <dt>At night</dt>

                <dd>
                  <input type="hidden" name="route[night]" value="false" />
                  <label>
                    <input type="checkbox" name="route[night]" value="true" checked={@service.night} />
                    Wake me at night for this
                  </label>

                  <span class="hint">Off holds its alerts until the night ends, if the issue is still open.</span>
                </dd>
              </dl>
            </form>

            <dl class="kv">
              <dt>Told</dt>

              <dd>
                <WhoPick.pick
                  scope="service"
                  id={@service.id}
                  people={@people}
                  who={@who}
                  above="Told as the rule or the default says."
                  disabled={@current_user.role != :owner}
                /> <span :if={@current_user.role != :owner} class="hint">An owner changes this.</span>
              </dd>
            </dl>
          </div>
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
