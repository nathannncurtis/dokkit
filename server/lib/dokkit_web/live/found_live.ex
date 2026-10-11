defmodule DokkitWeb.FoundLive do
  @moduledoc "Found: what a scan found on a machine, waiting to be watched or dismissed."
  use DokkitWeb, :live_view

  @kinds %{
    "port" => "Listening port",
    "service" => "Running service",
    "container" => "Container",
    "site" => "Web site",
    "job" => "Scheduled job"
  }

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_params(_params, _uri, socket),
    do: {:noreply, load(assign(socket, page_title: "Found"))}

  def handle_info(:issues_changed, socket),
    do: {:noreply, DokkitWeb.Auth.debounce(socket, :page, &load/1)}

  def handle_info({:settled, :page}, socket),
    do: {:noreply, DokkitWeb.Auth.settle(socket, :page, &load/1)}

  def handle_event("sweep", %{"do" => what} = params, socket) do
    ids = params["ids"] || []

    case {socket.assigns.current_user.role, what} do
      {:viewer, _} -> nil
      {_, "watch"} -> Dokkit.Found.watch(ids)
      {_, "dismiss"} -> Dokkit.Found.dismiss(ids)
      _ -> nil
    end

    {:noreply, load(socket)}
  end

  def handle_event("scan", %{"id" => id}, socket) do
    if socket.assigns.current_user.role != :viewer,
      do: DokkitWeb.ApiController.look_again(id, "page")

    {:noreply, load(socket)}
  end

  defp load(socket) do
    assign(socket,
      found: Enum.group_by(Dokkit.Found.list(), & &1.machine),
      machines: Enum.filter(Dokkit.Read.machines(), &(&1.kind == :enrolled)),
      scans: Dokkit.Found.scans()
    )
  end

  defp how(f), do: Map.get(@kinds, f.kind, f.kind)

  defp job_how("task-scheduler"), do: "Scheduled task"
  defp job_how("systemd-timer"), do: "systemd timer"
  defp job_how("cron"), do: "Cron entry"
  defp job_how("launchd"), do: "launchd job"
  defp job_how(_), do: "Scheduled job"

  defp watched_from_record?(f), do: f.kind == "job" and f.detail["record"] == "record"

  defp run_line(slug, f),
    do: "dokkit run --job #{slug} -- #{f.detail["command"] || "<the command>"}"

  defp scan_says(nil), do: nil
  defp scan_says(%{state: :queued}), do: "Asked. Waiting for the machine to take it."
  defp scan_says(%{state: :running}), do: "Looking now."

  defp scan_says(%{state: :ok, finished_at: at}),
    do: "Looked at #{DokkitWeb.Show.at(at)} UTC. What it found is below."

  defp scan_says(%{state: :fail, output: out}), do: "Could not look: " <> String.trim(out || "")

  defp scan_says(%{state: :refused, output: out}) do
    if String.starts_with?(out || "", "This program does not run that"),
      do: "This machine's program is too old to be asked.",
      else: "The machine refused: " <> String.trim(out || "")
  end

  def render(assigns) do
    assigns = assign(assigns, viewer: assigns.current_user.role == :viewer)

    ~H"""
    <Layouts.app active={:found} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">
          {if @found != %{}, do: "Found, waiting for you", else: @page_title}
        </h1>
      </div>

      <div class="body">
        <form class="card" id="found-form" phx-submit="sweep">
          <h2>
            What a scan found<span :if={@found != %{}} class="cnt">{@found
            |> Map.values()
            |> Enum.map(&length/1)
            |> Enum.sum()}</span>
            <span :if={@found != %{}} class="end">
              <button class="btn sm primary" name="do" value="watch" disabled={@viewer}>
                <.ic name="plus" />Watch selected
              </button>

              <button class="btn sm" name="do" value="dismiss" disabled={@viewer}>
                Dismiss selected
              </button>
            </span>
          </h2>

          <div :if={@found == %{}} class="empty">
            <.ic name="check-circle" />Nothing a scan found is waiting. Each machine looks itself over a little after it starts and once a day, and you can ask one to look again below.
          </div>

          <div :if={@found != %{}} class="lh cols-found">
            <span></span><span>Found</span><span>How it was found</span><span>What Dokkit saw</span><span></span>
          </div>

          <%= for {machine, items} <- @found do %>
            <div class="mg" role="group" aria-labelledby={"fh-#{machine.id}"}>
              <div class="grp">
                <span id={"fh-#{machine.id}"}>{machine.name}</span><span class="end"><span class="tag">{length(
                  items
                )} found</span></span>
              </div>

              <%= for f <- items do %>
                <label class="li slim kid hov cols-found">
                  <input
                    class="chk"
                    type="checkbox"
                    name="ids[]"
                    value={f.id}
                    aria-label={"Select " <> f.detail["label"]}
                  />
                  <div class="ti"><span>{f.detail["label"]}</span></div>

                  <span class="how">{if f.kind == "job", do: job_how(f.detail["source"]), else: how(f)}</span>
                  <span class="mute">{f.detail["saw"]}</span> <span></span>
                </label>
                <div :if={f.kind == "job"} class="lead" style="padding: 0 16px 12px 42px">
                  <div :if={f.detail["schedule"]}>
                    Schedule <code>{f.detail["schedule"]}</code> (read as UTC). {f.detail["schedule_note"]}
                  </div>
                  <div :if={!f.detail["schedule"]}>
                    No schedule Dokkit can read: {f.detail["schedule_note"]} A run that fails is noticed; a run that does not happen is not.
                  </div>
                  <div :if={f.detail["last_run"] || f.detail["last_result"]}>
                    Last run {f.detail["last_run"] || "not recorded"}, result {f.detail["last_result"] ||
                      "not recorded"}.
                  </div>
                  <div :if={f.detail["command"]}>
                    It runs, for you to recognise it, not to be run by Dokkit:
                    <code>{f.detail["command"]}</code>
                  </div>
                  <div :if={watched_from_record?(f)}>
                    <strong>Watched from this machine's own record.</strong>
                    Once watched, the program on this machine reads when it last ran and how it ended, and reports each new run. Nothing about the job changes.
                    It waits for its next run before it can be judged.
                  </div>
                  <div :if={!watched_from_record?(f)}>
                    <strong>Needs the wrapper.</strong>
                    Once watched, it waits for its first report. Wrap its command so each run is reported:
                    <span class="once">
                      <code class="mono" id={"wrap-#{f.id}"}>{run_line(Dokkit.Found.slug(f.key), f)}</code>
                      <button class="btn sm" type="button" data-copy={"#wrap-#{f.id}"}>Copy</button>
                    </span>
                    or, from the end of the script,
                    <span class="once">
                      <code class="mono" id={"ping-#{f.id}"}>dokkit ping {Dokkit.Found.slug(f.key)} ok</code>
                      <button class="btn sm" type="button" data-copy={"#ping-#{f.id}"}>Copy</button>
                    </span>
                    (<code>fail</code>
                    in place of <code>ok</code>
                    when it failed).
                  </div>
                  <div :for={n <- f.detail["limits"] || []} class="mute">{n}</div>
                </div>
                <div :if={f.kind == "container"} class="lead" style="padding: 0 16px 12px 42px">
                  Checked by connecting to port {f.detail["port"]} on this machine. A container that publishes no port cannot be checked, so it is not listed.
                </div>
              <% end %>
            </div>
          <% end %>

          <div :if={@found != %{}} class="foot">
            Nothing here is watched until you say so. Watching one adds a check that dokkit watch runs on that machine. Dokkit never runs a job's command; it only notices when it did not run.
          </div>
        </form>

        <div class="card" id="look-again">
          <h2>Look again</h2>
          <div :if={@machines == []} class="empty">No machine has joined yet.</div>
          <div
            :for={m <- @machines}
            class="li slim hov"
            id={"look-#{m.id}"}
            style="display: flex; align-items: center; gap: 12px; flex-wrap: wrap"
          >
            <div class="ti"><span>{m.name}</span></div>
            <span class="mute">{scan_says(@scans[m.id])}</span>
            <span class="end" style="margin-left: auto">
              <button
                class="btn sm"
                type="button"
                phx-click="scan"
                phx-value-id={m.id}
                disabled={@viewer}
              >
                Look again
              </button>
            </span>
          </div>
          <div class="foot">
            A look is read-only: the machine lists its services, ports, containers, sites and scheduled jobs with its own tools, which takes a few seconds, changes nothing and sends one list here.
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
