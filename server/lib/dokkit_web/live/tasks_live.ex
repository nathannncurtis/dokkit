defmodule DokkitWeb.TasksLive do
  @moduledoc "Found: tasks waiting to be accepted. Tasks: the accepted ones, and their runs."
  use DokkitWeb, :live_view
  alias Dokkit.Tasks

  @cols "minmax(0,1fr) 110px 150px 250px 84px;--ncols:minmax(140px,1fr) 64px 92px 68px 76px;--minw:528px"
  @run_cols "minmax(0,1fr) 110px 150px 110px 90px 90px 16px;--ncols:minmax(150px,1fr) 72px 96px 76px 80px 56px 16px;--minw:662px"

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_params(_params, _uri, socket) do
    title = if socket.assigns.live_action == :found, do: "Found", else: "Tasks"
    {:noreply, load(assign(socket, page_title: title))}
  end

  def handle_info(:issues_changed, socket), do: {:noreply, load(socket)}

  # Accepting a command to run on a machine is the owner's call.
  def handle_event(event, %{"id" => id, "command" => command} = params, socket)
      when event in ~w(accepted dismissed) do
    if socket.assigns.current_user.role == :owner,
      do: Tasks.decide(id, command, String.to_existing_atom(event), params["system"] == "true")

    {:noreply, load(socket)}
  end

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

  def handle_event("run", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    if user.role != :viewer, do: Tasks.run(id, user.name)
    {:noreply, load(socket)}
  end

  defp load(socket),
    do:
      assign(socket,
        found: Enum.group_by(Dokkit.Found.list(), & &1.machine),
        waiting: Tasks.waiting(),
        tasks: Tasks.accepted(),
        runs: Tasks.runs()
      )

  def render(assigns) do
    assigns =
      assign(assigns,
        cols: @cols,
        run_cols: @run_cols,
        owner: assigns.current_user.role == :owner,
        viewer: assigns.current_user.role == :viewer
      )

    ~H"""
    <Layouts.app active={@live_action} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">
          {if @live_action == :found and (@waiting != [] or @found != %{}),
            do: "Found, waiting for you",
            else: @page_title}
        </h1>
        
        <div :if={@live_action == :tasks and @waiting != []} class="end">
          <.link class="btn" navigate={~p"/found"}>
            <.ic name="binoculars" />{length(@waiting)} waiting to be accepted
          </.link>
        </div>
      </div>
      
      <div :if={@live_action == :found} class="body">
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
            <.ic name="check-circle" />Nothing a scan found is waiting. On a machine, dokkit scan looks and dokkit propose sends what it saw.
          </div>
          
          <div :if={@found != %{}} class="lh cols-found">
            <span></span><span>Found</span><span>How it was found</span><span>What Dokkit saw</span><span></span>
          </div>
          
          <%= for {machine, items} <- @found do %>
            <div class="grp">
              {machine.name}<span class="end"><span class="tag">{length(items)} found</span></span>
            </div>
            
            <label :for={f <- items} class="li slim hov cols-found">
              <input
                class="chk"
                type="checkbox"
                name="ids[]"
                value={f.id}
                aria-label={"Select " <> f.detail["label"]}
              />
              <div class="ti"><span>{f.detail["label"]}</span></div>
              
              <span class="how">{if f.kind == "port", do: "Listening port", else: "Running service"}</span>
              <span class="mute">{f.detail["saw"]}</span> <span></span>
            </label>
          <% end %>
          
          <div :if={@found != %{}} class="foot">
            Nothing here is watched until you say so. Watching one adds a check that dokkit watch runs on that machine.
          </div>
        </form>
        
        <div class="card">
          <h2>
            Tasks waiting to be accepted<span :if={@waiting != []} class="cnt">{length(@waiting)}</span>
          </h2>
          
          <div :if={@waiting == []} class="empty">
            <.ic name="check-circle" />No task is waiting to be accepted.
          </div>
          
          <div
            :for={t <- @waiting}
            class="li hov cols-act"
            style="--cols: minmax(0,1fr) auto"
            id={"task-#{t.id}"}
          >
            <div>
              <div class="ti"><.ic name="terminal-window" /><span>{t.name}</span></div>
               <code class="cmd">{t.command}</code>
              <div class="meta">
                <span class="tag">{t.machine.name}</span>
                <span :if={t.accepted}>The command changed since it was accepted</span>
              </div>
            </div>
            
            <div style="display:flex; gap:6px">
              <button
                :for={
                  {event, system, label} <- [
                    {"accepted", "false", "Accept"},
                    {"accepted", "true", "Accept, as the system account"},
                    {"dismissed", "false", "Dismiss"}
                  ]
                }
                class="btn"
                type="button"
                phx-click={event}
                phx-value-id={t.id}
                phx-value-command={t.command}
                phx-value-system={system}
                disabled={!@owner}
              >
                {label}
              </button>
            </div>
          </div>
          
          <div :if={@waiting != []} class="foot">
            Nothing here is run until the owner says so. A task runs only the command shown, on its own machine, under an ordinary account with no rights of its own unless it is accepted as the system account, and the machine must also allow that in its own configuration.
          </div>
        </div>
      </div>
      
      <div :if={@live_action == :tasks} class="body">
        <div class="card">
          <div :if={@tasks == []} class="empty">
            <.ic name="terminal-window" />No task has been accepted yet. Tasks that are waiting are under Found.
          </div>
          
          <div :if={@tasks != []} class="lh cols-task" style={"--cols:" <> @cols}>
            <span>Task</span><span>Machine</span><span>Last run</span><span>Result</span><span></span>
          </div>
          
          <div
            :for={%{task: t, last: last} <- @tasks}
            class="li hov cols-task"
            style={"--cols:" <> @cols}
          >
            <div>
              <div class="ti"><.ic name="terminal-window" /><span>{t.name}</span></div>
               <code class="cmd">{t.command}</code>
            </div>
            
            <span>
              <span class="tag">{t.machine.name}</span>
              <span :if={t.as_system} class="tag warn">System account</span>
            </span>
            
            <span class={["mono", !last && "mute"]}>{(last && at(last.inserted_at)) || "Never"}</span>
            <.state :if={last} run={last} /><span :if={!last}></span>
            <button class="btn" type="button" phx-click="run" phx-value-id={t.id} disabled={@viewer}>
              <.ic name="play" />Run
            </button>
          </div>
        </div>
        
        <div class="card runs">
          <h2>Recent runs<span :if={@runs != []} class="cnt">{length(@runs)}</span></h2>
          
          <div :if={@runs == []} class="empty">
            <.ic name="clock-countdown" />No task has run yet.
          </div>
          
          <div :if={@runs != []} class="lh" style={"--cols:" <> @run_cols}>
            <span>Task</span><span>Machine</span><span>Started</span><span>Result</span><span class="r">Took</span><span class="r">Exit code</span><span></span>
          </div>
          
          <details :for={r <- @runs} class="run" style={"--cols:" <> @run_cols} id={"run-#{r.id}"}>
            <summary class="li slim" style={"--cols:" <> @run_cols}>
              <div class="ti"><span>{r.task.name}</span></div>
               <span class="tag">{r.task.machine.name}</span>
              <span class="mono">{at(r.started_at || r.inserted_at)}</span> <.state run={r} />
              <span class="mono r">{took(r.duration_ms)}</span>
              <span class="mono r">{r.exit_code}</span> <.ic name="caret-down" />
            </summary>
             <pre class="logbox">{if r.output == "", do: "No output yet.", else: r.output}</pre>
          </details>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :run, :map, required: true

  defp state(assigns) do
    ~H"""
    <span :if={@run.state == :ok} class="tag">Finished</span>
    <span :if={@run.state == :fail} class="tag bad"><.ic name="warning" />Failed</span>
    <span :if={@run.state == :refused} class="tag bad"><.ic name="warning" />Refused</span>
    <span :if={@run.state == :running} class="tag">Running</span>
    <span :if={@run.state == :queued} class="tag">Waiting for the machine</span>
    """
  end
end
