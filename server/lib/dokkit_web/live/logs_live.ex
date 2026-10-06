defmodule DokkitWeb.LogsLive do
  use DokkitWeb, :live_view
  alias Dokkit.{Estate, Logs}

  @cols "--cols:120px 64px 110px 150px minmax(0,1fr);--ncols:112px 52px 72px 124px minmax(140px,1fr);--minw:588px"
  @levels [
    {"Every level", ""},
    {"Info and worse", "info"},
    {"Warnings and errors", "warn"},
    {"Errors", "error"}
  ]

  def mount(_params, _session, socket) do
    if connected?(socket), do: Logs.subscribe()
    {:ok, assign(socket, page_title: "Logs")}
  end

  def handle_params(params, _uri, socket) do
    service = params["s"] && Estate.service(params["s"])
    filter = %{q: params["q"] || "", level: params["level"] || "", service: service}
    {:noreply, load(assign(socket, filter: filter))}
  end

  def handle_info(:logs_changed, socket),
    do: {:noreply, DokkitWeb.Auth.debounce(socket, :page, &load/1)}

  def handle_info({:settled, :page}, socket),
    do: {:noreply, DokkitWeb.Auth.settle(socket, :page, &load/1)}

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("filter", %{"q" => q, "level" => level}, socket) do
    service = socket.assigns.filter.service

    query =
      for {k, v} <- [q: q, level: level, s: service && service.id], v not in [nil, ""], do: {k, v}

    {:noreply, push_patch(socket, to: ~p"/logs?#{query}", replace: true)}
  end

  defp load(socket) do
    f = socket.assigns.filter
    assign(socket, lines: Logs.list(q: f.q, level: f.level, service: f.service && f.service.id))
  end

  def render(assigns) do
    assigns = assign(assigns, cols: @cols, levels: @levels)

    ~H"""
    <Layouts.app active={:logs} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">Logs</h1>
      </div>
      <form class="filters" phx-change="filter" phx-submit="filter" id="log-filter">
        <label class="search">
          <.ic name="magnifying-glass" />
          <input
            type="search"
            name="q"
            value={@filter.q}
            placeholder="Filter log lines"
            aria-label="Filter"
            phx-debounce="300"
          />
        </label>
        <span class="dd">
          <select class="inp" name="level" aria-label="Level">
            <option :for={{text, value} <- @levels} value={value} selected={value == @filter.level}>
              {text}
            </option>
          </select>
          <.ic name="caret-down" />
        </span>
        <.link
          :if={@filter.service}
          class="btn"
          patch={~p"/logs"}
          aria-label="Clear the service filter"
        >
          {@filter.service.name} <.ic name="x" />
        </.link>
      </form>
      <div class="body">
        <div class="card">
          <div :if={@lines == []} class="empty"><.ic name="scroll" />No log lines match.</div>
          <div :if={@lines != []} class="lh cols-logs" style={@cols}>
            <span>Time</span><span>Level</span><span>Machine</span><span>Service</span><span>Message</span>
          </div>
          <div :for={l <- @lines} class="li slim cols-logs" style={@cols}>
            <span class="mono">{at(l.at)}</span>
            <span class={["tag", l.level in ~w(error fatal) && "bad", l.level == "warn" && "warn"]}>{String.capitalize(
              l.level
            )}</span> <span class="tag">{l.machine.name}</span>
            <.link :if={l.service} navigate={~p"/s/#{l.service_id}"}>{l.service.name}</.link>
            <span :if={!l.service} class="mute">The machine</span>
            <span>{l.msg}<span :if={l.cut} class="mute"> (cut)</span></span>
          </div>
          <div :if={length(@lines) == 200} class="foot">
            The newest 200 lines that match. Narrow the filter to see older ones.
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
