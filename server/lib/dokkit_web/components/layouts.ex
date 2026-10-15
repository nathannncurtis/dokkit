defmodule DokkitWeb.Layouts do
  use DokkitWeb, :html

  embed_templates "layouts/*"

  attr :active, :atom, required: true
  attr :shell, :map, required: true
  attr :user, :map, required: true
  slot :inner_block, required: true

  def app(%{shell: %{updating: %{}}} = assigns) do
    ~H"""
    <main class="updating" id="updating" aria-labelledby="updating-h">
      <div class="up">
        <.mark />
        <h1 id="updating-h" tabindex="-1">Updating to {@shell.updating.version}</h1>
        <div
          class="prog"
          role="progressbar"
          aria-label="Machines finished"
          aria-valuemin="0"
          aria-valuemax={@shell.updating.total}
          aria-valuenow={@shell.updating.done}
          aria-valuetext={"#{@shell.updating.done} of #{@shell.updating.total} finished"}
          style={"--v:#{div(@shell.updating.done * 100, @shell.updating.total)}%"}
        >
          <i></i>
        </div>
        <p class="up-count">{@shell.updating.done} of {@shell.updating.total} finished</p>
        <p class="up-restart" role="status">
          <.ic name="arrows-clockwise" />Dokkit is restarting. This screen carries on when it answers.
        </p>
        <ul class="up-list">
          <li :for={m <- @shell.updating.machines} id={"updating-#{m.id}"}>
            <span>{m.name}</span>
            <span class={["tag", m.state == :failed && "warn", m.state == :done && "ok"]}>
              <.ic name={step_icon(m.state)} />{step(m)}
            </span>
          </li>
        </ul>
      </div>
    </main>
    """
  end

  def app(assigns) do
    ~H"""
    <div class="shell">
      <nav class="side" aria-label="Main">
        <.link class="org" navigate={~p"/"}>
          <.mark /> <span><b>Dokkit</b></span>
        </.link>

        <%= for {heading, items} <- nav() do %>
          <h3>{heading}</h3>

          <.link
            :for={{id, icon, label, path} <- items}
            class={["nav", @active == id && "on"]}
            navigate={path}
            aria-label={count(@shell, id) && "#{label}, #{count(@shell, id)}"}
          >
            <i class={"ph ph-#{icon}"} aria-hidden="true"></i>{label}<span
              :if={count(@shell, id)}
              class="n"
            >{count(@shell, id)}</span>
          </.link>
        <% end %>

        <h3 :if={machines(@shell) != []}>Machines</h3>

        <.link :for={m <- machines(@shell)} class="nav" navigate={~p"/machines/#{m.id}"}>
          <span class={["dot", attention(m) > 0 && "warn"]}></span>{m.name}<span
            :if={attention(m) > 0}
            class="q"
          >{attention(m)}</span><span :if={attention(m) == 0 and soon(m) > 0} class="q">{soon(m)} soon</span><span :if={attention(m) == 0 and soon(m) == 0 and Map.get(m, :planned)} class="q">planned</span>
        </.link>
        <span class="grow"></span>
        <div class="me">
          <span class="av">{@user.name |> String.slice(0, 2) |> String.upcase()}</span>
          <span>{@user.name}</span>
          <form method="post" action={~p"/logout"}>
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button class="btn ghost sm" type="submit" aria-label="Sign out">
              <i class="ph ph-sign-out" aria-hidden="true"></i>
            </button>
          </form>
        </div>
      </nav>

      <main class="page" id="page" tabindex="-1">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  defp machines(shell), do: Enum.filter(shell.machines, &(&1.kind in [:enrolled, :seen]))

  defp step_icon(:done), do: "check-circle"
  defp step_icon(:failed), do: "x-circle"
  defp step_icon(_), do: "arrows-clockwise"

  defp step(%{state: :waiting}), do: "Waiting"
  defp step(%{state: :installing}), do: "Installing"
  defp step(%{state: :done}), do: "Done"
  defp step(%{note: note}), do: "Failed: #{note}"

  defp attention(m), do: Map.get(m, :attention, m.bad)
  defp soon(m), do: Map.get(m, :soon, 0)

  defp count(%{open: n}, :inbox) when n > 0, do: n
  defp count(%{waiting: n}, :found) when n > 0, do: n

  defp count(%{machines: machines}, :apps) do
    n = for m <- machines, m.kind == :group, reduce: 0, do: (acc -> acc + attention(m))
    if n > 0, do: n
  end

  defp count(_, _), do: nil

  defp nav do
    [
      {"Watch",
       [
         {:inbox, "tray", "Inbox", ~p"/"},
         {:all, "squares-four", "Everything", ~p"/all"},
         {:apps, "app-window", "Apps", ~p"/apps"},
         {:jobs, "clock-countdown", "Jobs", ~p"/jobs"},
         {:logs, "scroll", "Logs", ~p"/logs"},
         {:errors, "bug", "Errors", ~p"/errors"}
       ]},
      {"Changes",
       [
         {:deploys, "rocket-launch", "Deploys", ~p"/deploys"},
         {:versions, "git-branch", "Versions", ~p"/versions"}
       ]},
      {"Manage",
       [
         {:found, "binoculars", "Found", ~p"/found"},
         {:alerts, "bell", "Alerts", ~p"/alerts"},
         {:settings, "gear", "Settings", ~p"/settings"}
       ]}
    ]
  end

  def mark(assigns) do
    ~H"""
    <span class="mark">
      <svg viewBox="0 0 100 100" fill="currentColor" aria-hidden="true">
        <circle cx="27.5" cy="30.5" r="5.4"></circle>

        <path d="M39 25H53A23 23 0 0 1 53 71H28A4 4 0 0 1 24 67V43A4 4 0 0 1 28 39H33A4 4 0 0 1 37 43V60H53A12 12 0 0 0 53 36H39A3.5 3.5 0 0 1 35.5 32.5V28.5A3.5 3.5 0 0 1 39 25Z">
        </path>
      </svg>
    </span>
    """
  end
end
