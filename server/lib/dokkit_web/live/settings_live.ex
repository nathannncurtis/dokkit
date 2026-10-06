defmodule DokkitWeb.SettingsLive do
  use DokkitWeb, :live_view
  alias Dokkit.{Accounts, Keys}

  @key_cols "--cols:minmax(0,1.4fr) 110px 150px 150px 96px;--ncols:minmax(140px,1fr) 96px 124px 124px 88px;--minw:640px"
  @roles [{"Member", "member"}, {"Viewer", "viewer"}, {"Owner", "owner"}]
  @kinds %{enrol: "Enrolment token", machine: "Machine key", app: "App key", user: "User token"}

  def mount(_params, _session, socket) do
    {:ok, load(assign(socket, page_title: "Settings", error: nil, new_token: nil))}
  end

  def handle_info(:issues_changed, socket), do: {:noreply, socket}

  def handle_event("add", %{"person" => p}, socket) do
    owner(socket, fn ->
      case Accounts.add(p["name"], p["role"], p["password"]) do
        {:ok, _} -> assign(socket, error: nil)
        {:error, text} -> assign(socket, error: text)
      end
    end)
  end

  def handle_event("remove", %{"id" => id}, socket) do
    owner(socket, fn ->
      case Accounts.remove(id, socket.assigns.current_user) do
        :ok -> assign(socket, error: nil)
        {:error, text} -> assign(socket, error: text)
      end
    end)
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    owner(socket, fn ->
      Keys.revoke(id)
      socket
    end)
  end

  def handle_event("token", %{"token" => t}, socket) do
    owner(socket, fn ->
      scopes = for s <- ~w(read read-logs act), t[s] == "true", do: s
      label = String.trim(t["label"] || "")

      if label == "" or scopes == [] do
        assign(socket, error: "A token needs a name and at least one thing it may do.")
      else
        {text, _} = Keys.mint(:user, %{label: label, scopes: scopes})
        assign(socket, new_token: text, error: nil)
      end
    end)
  end

  defp owner(socket, fun) do
    socket = if socket.assigns.current_user.role == :owner, do: fun.(), else: socket
    {:noreply, load(socket)}
  end

  defp load(socket), do: assign(socket, people: Accounts.list(), keys: Keys.list())

  def render(assigns) do
    assigns =
      assign(assigns,
        key_cols: @key_cols,
        roles: @roles,
        kinds: @kinds,
        owner: assigns.current_user.role == :owner
      )

    ~H"""
    <Layouts.app active={:settings} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">Settings</h1>
      </div>
      <div class="body set">
        <p :if={@error} class="lead bad" role="alert">{@error}</p>
        <div class="card">
          <h2>People<span class="cnt">{length(@people)}</span></h2>
          <div :for={p <- @people} class="est" id={"person-#{p.id}"}>
            <b>{p.name}</b>
            <span style="display:flex; gap:8px; align-items:center">
              <span class="tag">{String.capitalize(to_string(p.role))}</span>
              <button
                :if={@owner and p.id != @current_user.id}
                class="btn sm"
                type="button"
                phx-click="remove"
                phx-value-id={p.id}
                data-confirm={"Remove #{p.name}? They are signed out at once."}
              >
                Remove
              </button>
            </span>
          </div>
          <form :if={@owner} class="foot" phx-submit="add" id="person-form">
            <input class="inp" name="person[name]" placeholder="Name" aria-label="Name" required />
            <span class="dd">
              <select class="inp" name="person[role]" aria-label="Role">
                <option :for={{text, value} <- @roles} value={value}>{text}</option>
              </select>
              <.ic name="caret-down" />
            </span>
            <input
              class="inp"
              type="password"
              name="person[password]"
              placeholder="A first password"
              aria-label="A first password"
              autocomplete="new-password"
              required
            />
            <span class="end"><button class="btn primary" type="submit">Add person</button></span>
          </form>
          <p class="lead">
            A member can do everything except manage people, keys and alert channels. A viewer can look and change nothing.
          </p>
        </div>
        <div class="card">
          <h2>Keys<span class="cnt">{length(@keys)}</span></h2>
          <p :if={@keys == []} class="lead">No keys yet. Adding a job or a machine makes one.</p>
          <div :if={@keys != []} class="lh cols-key" style={@key_cols}>
            <span>Key</span><span>Kind</span><span>Made</span><span>Last used</span><span></span>
          </div>
          <div :for={k <- @keys} class="li slim cols-key" style={@key_cols} id={"key-#{k.id}"}>
            <div>
              <div class="ti"><span>{k.label || holder(k)}</span></div>
              <div class="sub mono">
                {k.hint}{if k.scopes != [], do: "  " <> Enum.join(k.scopes, ", ")}
              </div>
            </div>
            <span class="tag">{@kinds[k.kind]}</span>
            <span class="mono">{at(k.inserted_at)}</span>
            <span :if={k.used_at} class="mono">{at(k.used_at)}</span>
            <span :if={!k.used_at} class="mute">Never</span>
            <button
              :if={@owner}
              class="btn sm"
              type="button"
              phx-click="revoke"
              phx-value-id={k.id}
              data-confirm="Revoke this key? Whatever uses it stops being heard."
            >
              Revoke
            </button>
            <span :if={!@owner}></span>
          </div>
        </div>
        <div :if={@owner} class="card">
          <h2>Access for scripts and AI tools</h2>
          <p class="lead">
            A user token reads Dokkit through the API. Give it only what it needs: log contents are a separate permission, and so is acting on issues.
          </p>
          <pre :if={@new_token} class="logbox" id="new-token">{@new_token}</pre>
          <form class="foot" phx-submit="token" id="token-form">
            <input
              class="inp"
              name="token[label]"
              placeholder="What it is for"
              aria-label="What it is for"
              required
            />
            <label><input type="checkbox" name="token[read]" value="true" checked /> Read</label>
            <label><input type="checkbox" name="token[read-logs]" value="true" /> Read logs</label>
            <label><input type="checkbox" name="token[act]" value="true" /> Snooze and acknowledge</label>
            <span :if={@new_token}>Shown only now.</span>
            <span class="end"><button class="btn primary" type="submit">Make a token</button></span>
          </form>
        </div>
        <div class="card">
          <h2>Appearance</h2>
          <dl class="kv">
            <dt>Theme</dt>
            <dd>
              <button class="btn" type="button" onclick="dokkitTheme('light')"><.ic name="sun" />Light</button>
              <button class="btn" type="button" onclick="dokkitTheme('dark')"><.ic name="moon" />Dark</button>
              <button class="btn" type="button" onclick="dokkitTheme(null)">Follow this device</button>
            </dd>
          </dl>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp holder(%{machine: %{name: name}}), do: name
  defp holder(%{service: %{name: name}}), do: name
  defp holder(_), do: "Unnamed"
end
