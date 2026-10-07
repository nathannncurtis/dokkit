defmodule DokkitWeb.EverythingLive do
  use DokkitWeb, :live_view
  alias Dokkit.Estate

  def mount(_params, _session, socket), do: {:ok, load(assign(socket, page_title: "Everything"))}

  def handle_info(:issues_changed, socket),
    do: {:noreply, DokkitWeb.Auth.debounce(socket, :page, &load/1)}

  def handle_info({:settled, :page}, socket),
    do: {:noreply, DokkitWeb.Auth.settle(socket, :page, &load/1)}

  def handle_event("update", %{"machine" => id}, socket),
    do: owner(socket, fn held -> Dokkit.Releases.approve(held, id) end)

  def handle_event("update_all", _, socket),
    do: owner(socket, fn held -> Dokkit.Releases.approve(held, :all) end)

  defp owner(socket, act) do
    held = Dokkit.Releases.newest()
    if socket.assigns.current_user.role == :owner and held, do: act.(held)
    {:noreply, load(socket)}
  end

  defp load(socket) do
    down = for m <- Dokkit.Issues.machines(), m.down, do: m.id
    machines = Estate.machines()
    held = Dokkit.Releases.newest()

    assign(socket,
      machines: machines,
      down: down,
      vitals: Dokkit.Numbers.vitals(),
      held: held,
      movable: Enum.count(machines, &can_move?(&1, held))
    )
  end

  defp can_move?(m, held) do
    m.has_updater and held != nil and
      (Dokkit.Releases.newer?(held, m.program_version) or
         (m.hosts_server and Dokkit.Releases.newer?(held, m.server_version))) and
      (is_nil(m.wanted_version) or m.update_ok == false)
  end

  # No updater: only a Windows machine is told how to get one.
  defp windows?(m),
    do: m.kind == :enrolled and String.contains?(String.downcase(m.os || ""), "windows")

  defp outcome(%{wanted_version: nil, update_ok: true, update_version: v}), do: "Updated to #{v}"

  defp outcome(%{update_ok: false, update_version: v, update_note: note}),
    do: "Update to #{v} failed: #{note}"

  defp outcome(%{wanted_version: v}) when is_binary(v), do: "Asked to move to #{v}"
  defp outcome(_), do: nil

  def render(assigns) do
    ~H"""
    <Layouts.app active={:all} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">Everything</h1>

        <div class="end">
          <button
            :if={@current_user.role == :owner and @movable > 1}
            class="btn"
            type="button"
            id="update-all"
            phx-click="update_all"
          >
            <.ic name="arrow-circle-up" />Update all to {@held}
          </button>
          <.link class="btn" navigate={~p"/machines/new"}><.ic name="hard-drives" />Add a machine</.link>
          <.link class="btn primary" navigate={~p"/jobs/new"}><.ic name="plus" />New job</.link>
        </div>
      </div>

      <div class="body">
        <div class="card">
          <div :if={@machines == []} class="empty">
            <.ic name="squares-four" />Nothing is being watched yet. Add a job to start.
          </div>

          <div :if={@machines != []} class="lh cols-all">
            <span>Service</span><span>Version</span><span>Listens</span><span>Kind</span><span></span><span>State</span><span></span>
          </div>

          <%= for m <- @machines do %>
            <div class="grp" id={"m-#{m.id}"}>
              <span style="display:flex; align-items:center; gap:8px"><.lvl state={
                if m.id in @down, do: :down, else: worst(m.services)
              } />{m.name}</span> <span :if={m.os} class="mute" style="font-weight:400">{m.os}</span>
              <span class="end">
                <span :if={m.id in @down} class="tag warn">Stopped reporting {at(m.last_seen_at)} UTC</span>
                <span :if={count(m.services, :bad) > 0} class="tag warn">{need(
                  count(m.services, :bad)
                )}</span>
                <span :if={count(m.services, :ok) > 0} class="tag">{count(m.services, :ok)} fine</span>
                <span :if={@vitals[m.id]} class="vits">
                  <span
                    :for={{name, label} <- [{"cpu.percent", "cpu"}, {"memory.used_percent", "mem"}]}
                    :if={v = @vitals[m.id][name]}
                    class={["vit", v >= 90 && "hot"]}
                  >
                    {label} <u style={"--v:#{round(v)}%"}><i></i></u> {round(v)}%
                  </span>
                </span>
              </span>
            </div>

            <div :if={m.has_updater} class="foot" id={"upd-#{m.id}"}>
              <span class="mono">
                Program {m.program_version || "unknown"}{m.hosts_server &&
                  " / Server #{m.server_version || "unknown"}"}
              </span>
              <span :if={outcome(m)} class={["st", m.update_ok == false && "warn"]}>{outcome(m)}</span>
              <span class="end">
                <button
                  :if={@current_user.role == :owner and can_move?(m, @held)}
                  class="btn sm"
                  type="button"
                  phx-click="update"
                  phx-value-machine={m.id}
                >
                  Update to {@held}
                </button>
              </span>
            </div>

            <div :if={!m.has_updater and windows?(m)} class="foot" id={"upd-#{m.id}"}>
              <span>No updater on this machine. On it, from an administrator prompt: <code>dokkit updater install</code></span>
            </div>

            <.link :for={s <- m.services} class="li slim cols-all" navigate={~p"/s/#{s.id}"}>
              <div class="ti"><.lvl state={s.state} /><span>{s.name}</span></div>
              <span class="mono mute">{s.version}</span> <span class="mono mute">{s.listens}</span>
              <span class="mute">{kind(s.kind)}</span> <span></span>
              <span class={["tag", s.state in [:degraded, :down] && "warn"]}>{(!s.watched &&
                                                                                 "Not watched") ||
                s.note || say(s.state)}</span> <.ic name="caret-right" />
            </.link>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp count(services, :bad), do: Enum.count(services, &(&1.state in [:degraded, :down]))
  defp count(services, :ok), do: Enum.count(services, &(&1.state == :ok))

  defp worst(services),
    do:
      if(count(services, :bad) > 0, do: :down, else: if(services == [], do: :unknown, else: :ok))

  defp need(1), do: "1 needs a look"
  defp need(n), do: "#{n} need a look"
end
