defmodule DokkitWeb.Layouts do
  use DokkitWeb, :html

  embed_templates "layouts/*"

  attr :active, :atom, required: true
  attr :shell, :map, required: true
  attr :user, :map, required: true
  slot :inner_block, required: true

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

        <h3 :if={@shell.machines != []}>Machines</h3>

        <.link :for={m <- @shell.machines} class="nav" navigate={~p"/all" <> "#m-#{m.id}"}>
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

  defp attention(m), do: Map.get(m, :attention, m.bad)
  defp soon(m), do: Map.get(m, :soon, 0)

  defp count(%{open: n}, :inbox) when n > 0, do: n
  defp count(%{waiting: n}, :found) when n > 0, do: n
  defp count(_, _), do: nil

  defp nav do
    [
      {"Watch",
       [
         {:inbox, "tray", "Inbox", ~p"/"},
         {:all, "squares-four", "Everything", ~p"/all"},
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
