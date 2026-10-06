defmodule DokkitWeb.Layouts do
  use DokkitWeb, :html

  embed_templates "layouts/*"

  attr :active, :atom, required: true
  attr :machines, :list, required: true
  attr :open, :integer, required: true
  attr :user, :map, required: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="shell">
      <nav class="side" aria-label="Main">
        <.link class="org" navigate={~p"/"}>
          <.mark />
          <span><b>Dokkit</b></span>
        </.link>
        <h3>Watch</h3>
        <.link
          class={["nav", @active == :inbox && "on"]}
          navigate={~p"/"}
          aria-label={"Inbox" <> if(@open > 0, do: ", #{@open}", else: "")}
        >
          <i class="ph ph-tray" aria-hidden="true"></i>Inbox<span :if={@open > 0} class="n">{@open}</span>
        </.link>
        <h3 :if={@machines != []}>Machines</h3>
        <span :for={m <- @machines} class="nav">
          <span class={["dot", m.state]}></span>{m.name}<span :if={m.bad > 0} class="q">{m.bad}</span>
        </span>
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
