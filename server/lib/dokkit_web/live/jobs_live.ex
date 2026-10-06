defmodule DokkitWeb.JobsLive do
  use DokkitWeb, :live_view
  alias Dokkit.Estate

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, added: nil, error: nil, form: %{})}

  def handle_params(_params, _uri, socket) do
    title = if socket.assigns.live_action == :new, do: "New job", else: "Jobs"
    {:noreply, load(assign(socket, page_title: title))}
  end

  def handle_info(:issues_changed, socket),
    do: {:noreply, DokkitWeb.Auth.debounce(socket, :page, &load/1)}

  def handle_info({:settled, :page}, socket),
    do: {:noreply, DokkitWeb.Auth.settle(socket, :page, &load/1)}

  def handle_event("add", %{"job" => params}, socket) do
    with true <- socket.assigns.current_user.role != :viewer,
         {:ok, added} <- Estate.add_job(params) do
      {:noreply, assign(socket, added: added, error: nil, form: %{})}
    else
      {:error, text} -> {:noreply, assign(socket, error: text, form: params)}
      false -> {:noreply, assign(socket, error: "A viewer cannot add jobs.", form: params)}
    end
  end

  defp load(socket), do: assign(socket, jobs: Estate.jobs())

  def render(assigns) do
    ~H"""
    <Layouts.app active={:jobs} shell={@shell} user={@current_user}>
      <div :if={@live_action == :new} class="crumb">
        <.link navigate={~p"/jobs"}>Jobs</.link><.ic name="caret-right" /><span>New job</span>
      </div>

      <div class="head">
        <h1 tabindex="-1">{@page_title}</h1>

        <div :if={@live_action == :index} class="end">
          <.link class="btn primary" patch={~p"/jobs/new"}><.ic name="plus" />New job</.link>
        </div>
      </div>

      <div :if={@live_action == :new and @added} class="body set">
        <div class="card">
          <h2>{@added.service.name} is being watched</h2>

          <p class="lead">
            Call these addresses from the job. They hold a key that is shown only now, so copy them before leaving this page. A request body sent to the last two is kept as the run's output.
          </p>

          <dl class="kv">
            <dt :for={event <- ~w(start ok fail)}>{label(event)}</dt>

            <dd :for={event <- ~w(start ok fail)}>
              <span class="mono" id={"ping-#{event}"}>{ping(@added, event)}</span>
            </dd>
          </dl>
          <pre class="logbox">{example(@added)}</pre>
          <div class="foot">
            <span class="end">
              <.link class="btn primary" navigate={~p"/s/#{@added.service.id}"}>Open {@added.service.name}</.link>
            </span>
          </div>
        </div>
      </div>

      <form :if={@live_action == :new and !@added} class="body set" phx-submit="add" id="job-form">
        <div class="card">
          <h2>What to watch</h2>

          <dl class="kv">
            <dt>Name</dt>

            <dd>
              <input
                class="inp"
                style="flex: 1 1 260px"
                name="job[name]"
                value={@form["name"]}
                placeholder="Nightly backup"
                required
                aria-label="Name"
              />
            </dd>

            <dt>Machine</dt>

            <dd>
              <input
                class="inp"
                style="flex: 1 1 260px"
                name="job[machine]"
                value={@form["machine"]}
                list="machines"
                placeholder="nas"
                required
                aria-label="Machine"
              />
              <datalist id="machines"><option :for={m <- @shell.machines} value={m.name}></option></datalist>
              <span class="hint">The machine it runs on. A new name adds the machine.</span>
            </dd>

            <dt>Schedule</dt>

            <dd>
              <input
                class="inp mono"
                style="flex: 1 1 260px"
                name="job[schedule]"
                value={@form["schedule"]}
                placeholder="0 1 * * *"
                aria-label="Schedule"
              />
              <span class="hint">A cron line, read as UTC. Leave it empty and Dokkit only hears about runs that report a failure.</span>
            </dd>

            <dt>Late after</dt>

            <dd>
              <input
                class="inp mono"
                style="width: 120px"
                name="job[grace]"
                value={@form["grace"]}
                placeholder="30m"
                aria-label="Late after"
              />
              <span class="hint">How long past its time a run may start before it counts as missed.</span>
            </dd>

            <dt>Too long after</dt>

            <dd>
              <input
                class="inp mono"
                style="width: 120px"
                name="job[max_runtime]"
                value={@form["max_runtime"]}
                placeholder="1h"
                aria-label="Too long after"
              /> <span class="hint">Only checked for runs that report their start.</span>
            </dd>
          </dl>

          <div class="foot">
            <span :if={@error} class="bad" role="alert">{@error}</span>
            <span class="end"><button class="btn primary" type="submit">Add the job</button></span>
          </div>
        </div>
      </form>

      <div :if={@live_action == :index} class="body">
        <div class="card">
          <div :if={@jobs == []} class="empty"><.ic name="clock-countdown" />No jobs yet.</div>

          <div :if={@jobs != []} class="lh cols-jobs">
            <span>Job</span><span>Machine</span><span>Schedule</span><span>Last good run</span><span></span><span>Last run</span><span></span>
          </div>

          <.link :for={j <- @jobs} class="li slim cols-jobs" navigate={~p"/s/#{j.service.id}"}>
            <div class="ti">
              <.lvl state={j.check.state} /><span>{Dokkit.Intake.label(j.service, j.check.name)}</span>
            </div>
            <span class="tag">{j.machine.name}</span>
            <span class="mono mute">{j.check.config["schedule"]}</span>
            <span class="mono">{if j.last && j.last.result != :ok, do: at(j.good)}</span>
            <span></span>
            <div class="meta">
              <span :if={j.last} class="mono ink">{at(j.last.started_at || j.last.finished_at)}</span>
              <.result :if={j.last} run={j.last} />
              <span :if={!j.last} class="mute">No run seen yet</span>
            </div>
            <.ic name="caret-right" />
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :run, :map, required: true

  def result(assigns) do
    ~H"""
    <span :if={@run.result == :ok} class="tag">Finished</span>
    <span :if={@run.result == :fail} class="tag bad"><.ic name="warning" />Failed</span>
    <span :if={@run.result == :running} class="tag">Running</span>
    """
  end

  defp label("start"), do: "When it starts"
  defp label("ok"), do: "When it finishes"
  defp label("fail"), do: "When it fails"

  defp ping(added, event),
    do: Dokkit.Intake.ping_url(added.key, added.service.slug, event)

  defp example(added) do
    """
    # With the dokkit program, which also sends the exit code, the time taken and the output:
    DOKKIT_URL=#{DokkitWeb.Endpoint.url()} DOKKIT_KEY=#{added.key} dokkit run --job #{added.service.slug} -- ./the-job.sh

    # With nothing but curl:
    curl -fsS #{ping(added, "start")}
    ./the-job.sh && curl -fsS #{ping(added, "ok")} || curl -fsS #{ping(added, "fail")}
    """
  end
end
