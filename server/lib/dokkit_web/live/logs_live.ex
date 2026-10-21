defmodule DokkitWeb.LogsLive do
  use DokkitWeb, :live_view
  alias Dokkit.{Estate, Logs}

  @levels [
    {"Every level", ""},
    {"Info and worse", "info"},
    {"Warnings and errors", "warn"},
    {"Errors", "error"}
  ]
  @windows [
    {"Any time", ""},
    {"Last 15 minutes", "15"},
    {"Last hour", "60"},
    {"Last 2 hours", "120"},
    {"Last day", "1440"},
    {"Last 7 days", "10080"}
  ]
  @columns [at: "Time", level: "Level", machine: "Machine", service: "Service", msg: "Message"]
  @keys ~w(q level m s since sort dir)

  def mount(_params, _session, socket) do
    if connected?(socket), do: Logs.subscribe()
    {:ok, assign(socket, page_title: "Logs", machines: Estate.machines())}
  end

  def handle_params(params, _uri, socket) do
    params = Map.take(params, @keys)
    socket = assign(socket, machines: Estate.machines())
    service = params["s"] && Estate.service(params["s"])

    filter = %{
      q: params["q"] || "",
      level: params["level"] || "",
      machine: params["m"] || "",
      since: params["since"] || "",
      service: service
    }

    {:noreply, load(assign(socket, filter: filter, params: params, order: order(params)))}
  end

  def handle_info(:logs_changed, socket),
    do: {:noreply, DokkitWeb.Auth.debounce(socket, :page, &load/1)}

  def handle_info({:settled, :page}, socket),
    do: {:noreply, DokkitWeb.Auth.settle(socket, :page, &load/1)}

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("filter", form, socket) do
    params = socket.assigns.params
    machine = form["m"] || params["m"]
    service = Map.get(form, "s", params["s"])
    service = if on_machine?(socket.assigns.machines, service, machine), do: service, else: nil

    merged =
      params
      |> Map.merge(%{"m" => machine, "s" => service})
      |> Map.merge(Map.take(form, ~w(q level since)))

    query = for k <- @keys, merged[k] not in [nil, ""], do: {k, merged[k]}

    {:noreply, push_patch(socket, to: ~p"/logs?#{query}", replace: true)}
  end

  defp on_machine?(_, nil, _), do: true
  defp on_machine?(_, _, m) when m in [nil, ""], do: true

  defp on_machine?(machines, service, machine),
    do:
      Enum.any?(
        machines,
        &(&1.id == machine and Enum.any?(&1.services, fn s -> s.id == service end))
      )

  @doc "The page's filter and order as options for `Dokkit.Logs`, from the address's parameters."
  def options(params) do
    [
      q: params["q"],
      level: params["level"],
      machine: uuid(params["m"]),
      service: uuid(params["s"]),
      from: since(params["since"]),
      order: order(params)
    ]
  end

  defp uuid(id) do
    case Ecto.UUID.cast(id || "") do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp since(minutes) do
    case Integer.parse(minutes || "") do
      {n, ""} when n > 0 -> DateTime.add(DateTime.utc_now(), -n * 60)
      _ -> nil
    end
  end

  defp order(params) do
    col = Enum.find(Keyword.keys(@columns), :at, &(to_string(&1) == params["sort"]))

    dir =
      case params["dir"] do
        "asc" -> :asc
        "desc" -> :desc
        _ -> if col == :at, do: :desc, else: :asc
      end

    {col, dir}
  end

  defp load(socket), do: assign(socket, lines: Logs.list(options(socket.assigns.params)))

  defp sort_link(params, {col, dir}, key) do
    next = if col == key and dir == :asc, do: "desc", else: if(col == key, do: "asc", else: nil)
    next = next || if(key == :at, do: "desc", else: "asc")

    query =
      params
      |> Map.merge(%{"sort" => to_string(key), "dir" => next})
      |> Enum.reject(&(elem(&1, 1) in [nil, ""]))

    ~p"/logs?#{query}"
  end

  # A machine's own row is offered only when a link chose it, so the filter it came with stays.
  defp services(machines, machine, chosen) do
    for m <- machines,
        machine in ["", m.id],
        s <- m.services,
        s.slug != "machine" or s.id == chosen do
      {if(machine == "", do: "#{s.name} on #{m.name}", else: s.name), s.id}
    end
  end

  defp lede([]), do: "No log lines match. Try another word, level, machine or time."

  defp lede(lines) do
    errors = Enum.count(lines, &(&1.level in ~w(error fatal)))
    warns = Enum.count(lines, &(&1.level == "warn"))

    {shown, them} =
      if length(lines) == 200,
        do: {"The newest 200 lines that match are shown.", "Of these"},
        else: {"#{plural(length(lines), "line matches", "lines match")}.", "Of them"}

    tail =
      case {errors, warns} do
        {0, 0} ->
          " #{them}, none is a warning or an error."

        {0, w} ->
          " #{them}, #{plural(w, "is a warning", "are warnings")}, and none is an error."

        {e, 0} ->
          " #{them}, #{plural(e, "is an error", "are errors")}."

        {e, w} ->
          " #{them}, #{plural(e, "is an error", "are errors")} and #{plural(w, "is a warning", "are warnings")}."
      end

    shown <> tail
  end

  defp plural(1, one, _), do: "1 #{one}"
  defp plural(n, _, many), do: "#{n} #{many}"

  defp level_class(level) when level in ~w(error fatal), do: "error"
  defp level_class("warn"), do: "warn"
  defp level_class(_), do: nil

  def render(assigns) do
    assigns =
      assign(assigns,
        levels: @levels,
        windows: @windows,
        columns: @columns,
        service_opts:
          services(
            assigns.machines,
            assigns.filter.machine,
            assigns.filter.service && assigns.filter.service.id
          ),
        csv: ~p"/logs.csv?#{Enum.reject(assigns.params, &(elem(&1, 1) in [nil, ""]))}"
      )

    ~H"""
    <Layouts.app active={:logs} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">Logs</h1>
        <p class="lede">{lede(@lines)}</p>
      </div>

      <form class="filters" phx-change="filter" phx-submit="filter" id="log-filter">
        <div class="seg" role="radiogroup" aria-label="Level">
          <label :for={{text, value} <- @levels}>
            <input type="radio" name="level" value={value} checked={value == @filter.level} />
            <span>{text}</span>
          </label>
        </div>

        <span class="dd">
          <select class="inp" name="m" aria-label="Machine">
            <option value="">Every machine</option>
            <option :for={m <- @machines} value={m.id} selected={m.id == @filter.machine}>
              {m.name}
            </option>
          </select>
          <.ic name="caret-down" />
        </span>

        <span class="dd">
          <select class="inp" name="s" aria-label="Service">
            <option value="">Every service</option>
            <option
              :for={{text, id} <- @service_opts}
              value={id}
              selected={@filter.service && @filter.service.id == id}
            >
              {text}
            </option>
          </select>
          <.ic name="caret-down" />
        </span>

        <span class="dd">
          <select class="inp" name="since" aria-label="Time">
            <option :for={{text, value} <- @windows} value={value} selected={value == @filter.since}>
              {text}
            </option>
          </select>
          <.ic name="caret-down" />
        </span>

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

        <.link
          :if={@filter.service}
          class="btn"
          patch={~p"/logs?#{Map.delete(@params, "s")}"}
          aria-label="Clear the service filter"
        >
          {@filter.service.name} <.ic name="x" />
        </.link>

        <a class="btn" href={@csv} download="dokkit-logs.csv" id="log-csv">
          <.ic name="download-simple" />Export CSV
        </a>
      </form>

      <div class="body">
        <div class="card log-card">
          <div :if={@lines == []} class="empty"><.ic name="scroll" />No log lines match.</div>

          <div :if={@lines != []} class="scroll">
            <table class="log-table" id="log-table">
              <thead>
                <tr>
                  <th
                    :for={{key, label} <- @columns}
                    scope="col"
                    aria-sort={
                      elem(@order, 0) == key &&
                        if(elem(@order, 1) == :asc, do: "ascending", else: "descending")
                    }
                  >
                    <.link patch={sort_link(@params, @order, key)} replace>
                      {label}<.ic name={
                        cond do
                          elem(@order, 0) != key -> "caret-up-down"
                          elem(@order, 1) == :asc -> "caret-up"
                          true -> "caret-down"
                        end
                      } />
                    </.link>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={l <- @lines} class={level_class(l.level)}>
                  <td class="at">{at(l.at)}</td>
                  <td>
                    <span class={[
                      "tag",
                      l.level in ~w(error fatal) && "bad",
                      l.level == "warn" && "warn"
                    ]}>{String.capitalize(l.level)}</span>
                  </td>
                  <td class="m">
                    <.link navigate={~p"/machines/#{l.machine_id}"} title={l.machine.name}>{l.machine.name}</.link>
                  </td>
                  <td class="s">
                    <.link :if={l.service} navigate={~p"/s/#{l.service_id}"}>{l.service.name}</.link>
                    <span :if={!l.service} class="mute">The machine</span>
                  </td>
                  <td class="msg">{l.msg}<span :if={l.cut} class="mute"> (cut)</span></td>
                </tr>
              </tbody>
            </table>
          </div>

          <div :if={length(@lines) == 200} class="foot">
            Older lines are not shown. Narrow the filter to reach them; Export CSV has every one.
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
