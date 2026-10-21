defmodule DokkitWeb.JobsLive do
  use DokkitWeb, :live_view
  alias Dokkit.Estate

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, added: nil, error: nil, form: %{}, values_result: nil)}

  def handle_params(_params, _uri, socket) do
    title = if socket.assigns.live_action == :new, do: "New job", else: "Jobs"
    {:noreply, load(assign(socket, page_title: title))}
  end

  def handle_info(:issues_changed, socket),
    do: {:noreply, DokkitWeb.Auth.debounce(socket, :page, &load/1)}

  def handle_info({:settled, :page}, socket),
    do: {:noreply, DokkitWeb.Auth.settle(socket, :page, &load/1)}

  def handle_event("add", %{"job" => params}, socket) do
    with true <- socket.assigns.current_user.role == :owner,
         {:ok, added} <- Estate.add_job(params) do
      {:noreply, assign(socket, added: added, error: nil, form: %{})}
    else
      {:error, text} -> {:noreply, assign(socket, error: text, form: params)}
      false -> {:noreply, assign(socket, error: "An owner adds jobs.", form: params)}
    end
  end

  def handle_event(event, %{"target" => id} = params, socket)
      when event in ~w(values_save values_reset) do
    job = Enum.find(socket.assigns.jobs, &(&1.service.id == id))

    if socket.assigns.current_user.role != :owner or is_nil(job) do
      {:noreply, socket}
    else
      result =
        if event == "values_save",
          do: DokkitWeb.ValuesForm.save({:job, id}, params),
          else: DokkitWeb.ValuesForm.reset({:job, id}, params)

      {:noreply, assign(load(socket), values_result: result)}
    end
  end

  defp load(socket), do: assign(socket, jobs: Estate.jobs())

  defp lede(:new, _),
    do: "Tell Dokkit when a job should run, and it says when a run is missed or fails."

  defp lede(_, []), do: "No jobs yet. Add one and Dokkit watches every run."

  defp lede(_, jobs) do
    running = Enum.count(jobs, &(&1.last && &1.last.result == :running))
    trouble = Enum.count(jobs, &(&1.check && &1.check.state in [:down, :degraded]))

    "#{plural(length(jobs), "job", "jobs")}." <>
      if(running > 0, do: " #{running} running now.", else: "") <>
      if(trouble > 0,
        do: " #{plural(trouble, "needs", "need")} a look.",
        else: " None needs a look."
      )
  end

  defp plural(1, one, _), do: "1 #{one}"
  defp plural(n, _, many), do: "#{n} #{many}"

  def render(assigns) do
    ~H"""
    <Layouts.app active={:jobs} shell={@shell} user={@current_user}>
      <div :if={@live_action == :new} class="crumb">
        <.link navigate={~p"/jobs"}>Jobs</.link><.ic name="caret-right" /><span>New job</span>
      </div>

      <div class="head">
        <h1 tabindex="-1">{@page_title}</h1>

        <p class="lede">{lede(@live_action, @jobs)}</p>

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
            <span :if={@current_user.role != :owner} class="hint">An owner adds jobs.</span>
            <span class="end">
              <button class="btn primary" type="submit" disabled={@current_user.role != :owner}>
                Add the job
              </button>
            </span>
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
            <span class="tag" title={j.machine.name}>{j.machine.name}</span>
            <span class="mono mute">{j.check.config["schedule"]}</span>
            <span class="mono">{if j.last && j.last.result != :ok, do: at(j.good)}</span>
            <span><.progress :if={j.last} run={j.last} /></span>
            <div class="meta">
              <span :if={j.last} class="mono ink">{at(j.last.started_at || j.last.finished_at)}</span>
              <.result :if={j.last} run={j.last} />
              <span :if={!j.last} class="mute">No run seen yet</span>
            </div>
            <.ic name="caret-right" />
          </.link>
        </div>

        <DokkitWeb.ValuesForm.fold
          :for={j <- @jobs}
          id={"job-#{j.service.id}"}
          group="jobs"
          scope={{:job, j.service.id}}
          target={j.service.id}
          title={"Settings for #{Dokkit.Intake.label(j.service, j.check.name)}"}
          sub="When it counts as late, too long or missed. Each starts at the job's own file, or the default for every job."
          disabled={@current_user.role != :owner}
          result={@values_result}
        />
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

  attr :run, :map, required: true

  def progress(assigns) do
    ~H"""
    <span :if={@run.result == :running and @run.done} class="vit">
      <u
        :if={@run.total && @run.total > 0}
        style={"--v:#{min(100, round(@run.done * 100 / @run.total))}%"}
      ><i></i></u> {if @run.total,
        do: "#{num(@run.done)} of #{num(@run.total)}",
        else: "#{num(@run.done)} done"}
    </span>
    """
  end

  defp num(n), do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+$)/, ",")

  defp label("start"), do: "When it starts"
  defp label("ok"), do: "When it finishes"
  defp label("fail"), do: "When it fails"

  defp ping(added, event),
    do: Dokkit.Intake.ping_url(added.key, added.service.slug, event)

  defp example(added) do
    """
    # With the dokkit program, which also sends the exit code, the time taken and the output:
    DOKKIT_URL=#{Dokkit.Certificate.url()} DOKKIT_KEY=#{added.key} dokkit run --job #{added.service.slug} -- ./the-job.sh

    # With nothing but curl:
    curl -fsS #{ping(added, "start")}
    ./the-job.sh && curl -fsS #{ping(added, "ok")} || curl -fsS #{ping(added, "fail")}
    """
  end
end
