defmodule DokkitWeb.MachineCards do
  @moduledoc "The cards that show a machine's own history and processes."
  use DokkitWeb, :html

  attr :history, :list, required: true
  attr :range, :string, required: true
  attr :ranges, :list, required: true

  def history(assigns) do
    ~H"""
    <div class="card" id="history">
      <h2>
        History
        <span class="end">
          <form phx-change="range" id="range-form">
            <span class="dd">
              <select class="inp" name="range" aria-label="Show">
                <option :for={{v, text, _} <- @ranges} value={v} selected={v == @range}>
                  {text}
                </option>
              </select>
               <.ic name="caret-down" />
            </span>
          </form>
        </span>
      </h2>
      
      <p :if={@history == []} class="lead">
        No readings yet. This machine's disks, memory and processor appear here once it reports them.
      </p>
      
      <div :for={h <- @history} class="chart" id={"history-" <> h.name}>
        <div class="top">
          <b>{title(h.name)}</b>
          <span class="mono">{latest(h.points) && "#{Float.round(latest(h.points), 1)}%"}</span>
          <span :if={h.note} class="st warn">{h.note}</span>
        </div>
         <DokkitWeb.Show.line points={h.points} limit={h.limit} label={title(h.name)} />
      </div>
    </div>
    """
  end

  attr :procs, :map, required: true
  attr :procs_q, :string, required: true
  attr :procs_sort, :string, required: true
  attr :procs_all, :boolean, required: true
  attr :procs_history, :boolean, required: true

  def processes(assigns) do
    ~H"""
    <div class="card procs" id="processes">
      <h2>
        Processes
        <span class="end">
          {if @procs.list.at, do: "Taken #{at(@procs.list.at)} UTC", else: "None received yet"}
        </span>
      </h2>
      
      <p :if={!@procs.list.at} class="lead">
        No process list yet. The installed program sends one about once a minute.
      </p>
      
      <div :if={@procs.list.at} class="p-ctl">
        <form phx-change="procs_filter" phx-submit="procs_filter" id="procs-form">
          <input
            class="inp"
            type="search"
            name="q"
            value={@procs_q}
            placeholder="Filter by name or path"
            aria-label="Filter processes by name or path"
            autocomplete="off"
            phx-debounce="300"
          />
        </form>
        
        <span role="group" aria-label="Sort by" style="display: flex; gap: 8px">
          <button
            class={["btn sm", @procs_sort == "memory" && "primary"]}
            type="button"
            phx-click="procs_sort"
            phx-value-sort="memory"
            aria-pressed={to_string(@procs_sort == "memory")}
          >
            Memory
          </button>
          
          <button
            class={["btn sm", @procs_sort == "cpu" && "primary"]}
            type="button"
            phx-click="procs_sort"
            phx-value-sort="cpu"
            aria-pressed={to_string(@procs_sort == "cpu")}
          >
            Processor
          </button>
        </span>
      </div>
      
      <p :if={@procs.list.at && @procs.list.items == []} class="lead">
        No process matches.
      </p>
      
      <div :if={@procs.list.items != []} class="lh p-row">
        <span>Name</span><span class="r">PID</span><span class="r">Memory</span><span class="r">Processor</span><span class="p-path">Path</span>
      </div>
      
      <div :for={p <- @procs.list.items} class="li slim p-row" id={"proc-#{p["pid"]}"}>
        <span title={p["name"]}>{p["name"]}</span> <span class="mono r">{p["pid"]}</span>
        <span class="mono r">
          {mb(p["memory_bytes"])}{p["memory_percent"] && " · #{Float.round(p["memory_percent"], 1)}%"}
        </span>
         <span class="mono r">{percent(p["cpu_percent"])}</span>
        <span class="mono p-path" title={p["path"]}>{p["path"]}</span>
      </div>
      
      <div :if={@procs.list.at} class="foot">
        <button
          :if={@procs.list.count > 50 || @procs_all}
          class="btn sm"
          type="button"
          phx-click="procs_all"
        >
          {if @procs_all, do: "Show the top 50", else: "Show all #{@procs.list.count}"}
        </button>
        
        <button class="btn sm ghost" type="button" phx-click="procs_history">
          {if @procs_history, do: "Hide the last hour", else: "Show the last hour"}
        </button>
      </div>
      
      <p :if={@procs_history && @procs.history == []} class="lead">
        Nothing was kept for the last hour.
      </p>
      
      <div
        :for={h <- @procs.history}
        :if={@procs_history}
        class="li slim"
        style="--cols: 56px minmax(0,1fr)"
      >
        <span class="mono">{hhmm(h.at)}</span>
        <span
          class="mono"
          style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap"
          title={top_line(h.items, @procs_sort, 10)}
        >
          {top_line(h.items, @procs_sort, 3)}
        </span>
      </div>
    </div>
    """
  end

  def mb(bytes), do: "#{Integer.to_string(round(bytes / 1_048_576))} MB"
  def percent(nil), do: "-"
  def percent(n), do: "#{Float.round(n * 1.0, 1)}%"
  defp hhmm(%DateTime{} = t), do: Calendar.strftime(t, "%H:%M")

  def top_line(items, "cpu", n),
    do: Enum.map_join(Enum.take(items, n), ", ", &"#{&1["name"]} #{percent(&1["cpu_percent"])}")

  def top_line(items, _, n),
    do: Enum.map_join(Enum.take(items, n), ", ", &"#{&1["name"]} #{mb(&1["memory_bytes"])}")

  defp latest(points),
    do: points |> Enum.map(& &1.value) |> Enum.reject(&is_nil/1) |> List.last()

  def title("memory.used_percent"), do: "Memory in use"
  def title("cpu.percent"), do: "Processor in use"
  def title("disk.used_percent." <> disk), do: "Disk #{disk} in use"
  def title(name), do: name
end
