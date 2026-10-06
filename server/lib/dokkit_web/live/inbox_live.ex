defmodule DokkitWeb.InboxLive do
  use DokkitWeb, :live_view
  alias Dokkit.{Issue, Issues}

  def mount(_params, _session, socket) do
    if connected?(socket), do: Issues.subscribe()
    {:ok, load(socket)}
  end

  def handle_info(:issues_changed, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    issues = Issues.open_list()
    assign(socket, page_title: "Inbox", issues: issues, machines: Issues.machines())
  end

  def render(assigns) do
    ~H"""
    <Layouts.app active={:inbox} machines={@machines} open={length(@issues)}>
      <div class="head">
        <h1 tabindex="-1">Inbox</h1>
      </div>
      <div class="tabs" role="tablist">
        <button type="button" role="tab" aria-selected="true" class="on">
          Needs you<span :if={@issues != []} class="cnt">{length(@issues)}</span>
        </button>
      </div>
      <div class="body rail">
        <div class="card">
          <div :if={@issues == []} class="empty">
            <i class="ph ph-check-circle" aria-hidden="true"></i>Nothing needs you, and Dokkit will tell you when something does.
          </div>
          <div :if={@issues != []} class="lh cols-inbox plain">
            <span>Issue</span><span class="r">Count</span><span>Machine</span>
          </div>
          <div :for={i <- @issues} class="li cols-inbox plain" id={"issue-#{i.id}"}>
            <div>
              <div class="ti">
                <span class={["lvl", "warn"]} role="img" aria-label="Needs a look"></span><span>{i.title}</span>
              </div>
              <div :if={i.check.note} class="sub">{i.check.note}</div>
              <div class="meta">
                <span class="tag">{kind(i)}</span><span class="mono">{Issue.short_id(i)}</span><span>Since {since(
                  i.since
                )}</span>
              </div>
            </div>
            <div class="num">
              {i.count}<small>{if i.count == 1, do: "time", else: "times"}</small>
            </div>
            <span class="tag">{i.machine.name}</span>
          </div>
        </div>
        <div class="card">
          <h2>Estate</h2>
          <div :if={@machines == []} class="empty">No machines yet.</div>
          <div :for={m <- @machines} class="est">
            <b><span class={["lvl", m.state]}></span>{m.name}</b>
            <span class={["st", m.bad > 0 && "warn"]}>{estate(m)}</span>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp kind(%Issue{kind: "job"}), do: "Job"
  defp kind(_), do: "Check"

  defp since(at), do: Calendar.strftime(at, "%b %-d %H:%M") <> " UTC"

  defp estate(%{bad: 0, services: 0}), do: "nothing on it yet"
  defp estate(%{bad: 0}), do: "fine"
  defp estate(%{bad: 1}), do: "1 needs a look"
  defp estate(%{bad: n}), do: "#{n} need a look"
end
