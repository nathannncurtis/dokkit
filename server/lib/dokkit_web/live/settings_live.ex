defmodule DokkitWeb.SettingsLive do
  use DokkitWeb, :live_view
  alias Dokkit.{Accounts, Keys}

  @key_cols "--cols:minmax(0,1.4fr) 110px 150px 150px 96px;--ncols:minmax(140px,1fr) 96px 124px 124px 88px;--minw:640px"
  @roles [{"Member", "member"}, {"Viewer", "viewer"}, {"Owner", "owner"}]
  @kinds %{enrol: "Enrolment token", machine: "Machine key", app: "App key", user: "User token"}

  def mount(_params, _session, socket) do
    {:ok,
     load(
       assign(socket,
         page_title: "Settings",
         error: nil,
         new_token: nil,
         full: false,
         full_ok: false,
         cert_result: nil,
         cert_n: 0,
         acme_result: nil,
         acme_busy: false,
         acme_n: 0
       )
     )}
  end

  def handle_info(:issues_changed, socket), do: {:noreply, socket}

  def handle_info({:renewed, result}, socket) do
    result =
      case result do
        {:ok, note} -> {:ok, note}
        {:error, text} -> {:error, text}
      end

    {:noreply, load(assign(socket, acme_busy: false, acme_result: result))}
  end

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

  def handle_event("restore", %{"name" => name}, socket) do
    owner(socket, fn ->
      # Only a file that is listed, never a path from the browser.
      Dokkit.Logs.restore_named(name)
      socket
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
        {text, _} =
          Keys.mint(:user, %{
            label: label,
            scopes: scopes,
            user_id: socket.assigns.current_user.id
          })

        assign(socket, new_token: text, error: nil)
      end
    end)
  end

  def handle_event("full", _, socket),
    do: {:noreply, assign(socket, full: !socket.assigns.full, full_ok: false, full_form: %{})}

  def handle_event("full_typed", %{"full" => f}, socket),
    do: {:noreply, assign(socket, full_ok: sure?(f), full_form: f)}

  # Everything a person can do, so it is asked for on its own and confirmed by typing the address.
  def handle_event("full_token", %{"full" => f}, socket) do
    owner(socket, fn ->
      label = String.trim(f["label"] || "")

      if sure?(f) do
        {text, _} =
          Keys.mint(:user, %{
            label: label,
            scopes: ~w(read read-logs act admin),
            user_id: socket.assigns.current_user.id
          })

        assign(socket, new_token: text, error: nil, full: false, full_ok: false, full_form: %{})
      else
        text =
          if label == "",
            do: "Say what the token is for.",
            else: "Type #{Dokkit.Certificate.address()} exactly, and tick the box."

        assign(socket, error: text, full_form: f)
      end
    end)
  end

  def handle_event("certificate_save", %{"certificate" => c}, socket) do
    socket = assign(socket, cert_n: socket.assigns.cert_n + 1)

    owner(socket, fn ->
      case Dokkit.Certificate.put(c["cert"], c["key"]) do
        {:ok, _} -> assign(socket, cert_result: {:ok, "Saved"})
        {:error, text} -> assign(socket, cert_result: {:error, text})
      end
    end)
  end

  def handle_event("acme_save", %{"acme" => a}, socket) do
    socket = assign(socket, acme_n: socket.assigns.acme_n + 1)
    a = if a["acme_cloudflare_token"] == "", do: Map.delete(a, "acme_cloudflare_token"), else: a

    owner(socket, fn ->
      case Dokkit.Acme.save(a) do
        {:ok, _} -> assign(socket, acme_result: {:ok, "Saved"})
        {:error, text} -> assign(socket, acme_result: {:error, text})
      end
    end)
  end

  def handle_event("acme_now", _, socket) do
    if socket.assigns.current_user.role == :owner and not socket.assigns.acme_busy do
      lv = self()
      Task.start(fn -> send(lv, {:renewed, Dokkit.Acme.renew()}) end)
      {:noreply, assign(socket, acme_busy: true, acme_result: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("certificate_remove", _, socket) do
    owner(socket, fn ->
      case Dokkit.Certificate.delete() do
        {:ok, _} -> assign(socket, cert_result: {:ok, "Removed"})
        {:error, text} -> assign(socket, cert_result: {:error, text})
      end
    end)
  end

  defp sure?(f),
    do:
      Dokkit.Certificate.mine?(String.trim(f["confirm"] || "")) and f["sure"] == "true" and
        String.trim(f["label"] || "") != ""

  defp owner(socket, fun) do
    socket = if socket.assigns.current_user.role == :owner, do: fun.(), else: socket
    {:noreply, load(socket)}
  end

  defp load(socket) do
    dir = Application.get_env(:dokkit, :archive)

    assign(socket,
      people: Accounts.list(),
      keys: Keys.list(),
      releases: Dokkit.Releases.list(),
      certificates: Dokkit.Certificate.view(),
      acme: Dokkit.Acme.view(),
      archives: (dir && Dokkit.Logs.archives(dir)) || []
    )
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        key_cols: @key_cols,
        roles: @roles,
        kinds: @kinds,
        bases: [{"neutral", "Neutral"}, {"plum", "Plum"}, {"slate", "Slate"}, {"ember", "Ember"}],
        accents: [{"violet", "Violet"}, {"orange", "Orange"}, {"blue", "Blue"}, {"teal", "Teal"}],
        host: Dokkit.Certificate.address(),
        owner: assigns.current_user.role == :owner
      )

    ~H"""
    <Layouts.app active={:settings} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">Settings</h1>
        <a class="btn ghost sm" href={~p"/two-step"}>Two-step sign-in</a>
        <a class="btn ghost sm" href={~p"/password"}>Change password</a>
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
            /> <span class="end"><button class="btn primary" type="submit">Add person</button></span>
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

            <span class={["tag", "admin" in k.scopes && "bad"]}>
              {if "admin" in k.scopes, do: "Full control", else: @kinds[k.kind]}
            </span>
            <span class="mono">{at(k.inserted_at)}</span>
            <span :if={k.used_at} class="mono">{at(k.used_at)}</span>
            <span :if={!k.used_at and k.kind == :enrol} class="mono left">
              Unused, {Keys.left(k, DateTime.utc_now())} left
            </span>
            <span :if={!k.used_at and k.kind != :enrol} class="mute">Never</span>
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

        <div :if={@owner} class="card" id="releases">
          <h2>Releases<span class="end">Held for the updaters to fetch</span></h2>

          <p :if={@releases == []} class="lead">
            No release is held. The release workflow puts one here with PUT /api/v1/releases.
          </p>

          <div
            :for={r <- @releases}
            class="li slim"
            style="--cols: minmax(0,1fr) auto"
            id={"release-#{r.version}"}
          >
            <div>
              <div class="ti"><span class="mono">{r.version}</span></div>

              <div class="sub mono">{Enum.join(r.files, ", ")}</div>
            </div>

            <span class={["tag", !r.complete && "warn"]}>
              {if r.complete, do: "Complete", else: "Incomplete"}
            </span>
          </div>
        </div>

        <div :if={@owner} class="card" id="certificate">
          <h2>Certificate</h2>

          <div
            :for={
              {label, c} <- [
                {"Installed", @certificates.installed},
                {"Uploaded", @certificates.uploaded}
              ]
            }
            class="est"
            id={"certificate-#{String.downcase(label)}"}
          >
            <b>{label}</b> <span :if={!c} class="mute">None</span>
            <span :if={c}>
              <span class="mono">{Enum.join(c.names, ", ")}</span> {c.issuer}, runs out {String.slice(
                c.not_after,
                0,
                10
              )} <span :if={c.self_signed} class="tag">self-signed</span>
            </span>
          </div>

          <p class="lead">
            A certificate for a real name, with its chain after it, is served to clients that ask for that name. Machines pinned to the installed certificate are not affected.
          </p>

          <form
            style="display:grid; gap:12px; padding:12px 16px 0"
            phx-submit="certificate_save"
            id={"certificate-form-#{@cert_n}"}
          >
            <label style="display:grid; gap:6px">
              Certificate and chain <textarea
                class="inp"
                style="height:auto; padding:8px 10px; width:100%; resize:vertical"
                name="certificate[cert]"
                rows="4"
                spellcheck="false"
                required
              ></textarea>
            </label>

            <label style="display:grid; gap:6px">
              Private key <textarea
                class="inp"
                style="height:auto; padding:8px 10px; width:100%; resize:vertical"
                name="certificate[key]"
                rows="4"
                spellcheck="false"
                autocomplete="off"
                required
              ></textarea>
            </label>

            <span class="foot" style="padding-inline:0; margin-inline:-16px; padding-inline:16px">
              <span
                :if={@cert_result}
                class={elem(@cert_result, 0) == :error && "bad"}
                role="status"
                id="certificate-result"
              >
                {elem(@cert_result, 1)}
              </span>

              <span class="end">
                <button
                  :if={@certificates.uploaded}
                  class="btn"
                  type="button"
                  phx-click="certificate_remove"
                  data-confirm="Remove the uploaded certificate?"
                >
                  Remove
                </button>
                <button class="btn primary" type="submit">Save</button>
              </span>
            </span>
          </form>

          <form
            style="display:grid; gap:12px; padding:12px 16px 0"
            phx-submit="acme_save"
            id={"acme-form-#{@acme_n}"}
          >
            <p class="lead" style="margin:0">
              Dokkit can get this certificate and renew it by itself from Let's Encrypt, proving the name with a DNS record at Cloudflare.
            </p>

            <label style="display:grid; gap:6px">
              DNS name
              <input
                class="inp"
                name="acme[acme_name]"
                value={@acme["acme_name"]}
                placeholder="example.dokkit.dev"
                autocomplete="off"
                spellcheck="false"
              />
            </label>

            <label style="display:grid; gap:6px">
              Cloudflare API token that may edit DNS in that name's zone
              <input
                class="inp"
                type="password"
                name="acme[acme_cloudflare_token]"
                placeholder={if @acme["acme_cloudflare_token"] == "set", do: "set", else: "not set"}
                autocomplete="new-password"
              />
            </label>

            <label style="display:grid; gap:6px">
              Certificate authority directory
              <input
                class="inp"
                name="acme[acme_directory]"
                value={@acme["acme_directory"]}
                autocomplete="off"
                spellcheck="false"
              />
            </label>

            <span class="foot" style="padding-inline:16px; margin-inline:-16px">
              <span
                :if={@certificates.renewal}
                class={@certificates.renewal.ok == false && "bad"}
                id="certificate-renewal"
              >
                {@certificates.renewal.note}
              </span>
              <span :if={@acme_busy} role="status">Working, this takes a few minutes.</span>
              <span
                :if={@acme_result}
                class={elem(@acme_result, 0) == :error && "bad"}
                role="status"
                id="acme-result"
              >
                {elem(@acme_result, 1)}
              </span>

              <span class="end">
                <button class="btn" type="button" phx-click="acme_now" disabled={@acme_busy}>
                  Get a certificate now
                </button>
                <button class="btn primary" type="submit">Save</button>
              </span>
            </span>
          </form>
        </div>

        <div :if={@owner} class="card">
          <h2>Access for scripts and AI tools</h2>

          <p class="lead">
            A user token reads Dokkit through the API. Give it only what it needs: log contents are a separate permission, and so is acting on issues.
          </p>

          <div :if={@new_token} class="once">
            <span class="mono" id="new-token">{@new_token}</span>
            <button class="btn sm" type="button" data-copy="#new-token">Copy</button>
          </div>

          <p :if={@new_token} class="lead" style="padding-top: 0">
            Shown only now. Send it with each request as
            <code>Authorization: Bearer &lt;token&gt;</code>
            to <code>{Dokkit.Certificate.url()}/api/v1/machines</code>
            for a first try; AI tools use <code>{Dokkit.Certificate.url()}/mcp</code>.
          </p>

          <form class="foot" phx-submit="token" id="token-form">
            <input
              class="inp"
              name="token[label]"
              placeholder="What will use it"
              aria-label="What it is for"
              required
            /> <label><input type="checkbox" name="token[read]" value="true" checked /> Read</label>
            <label><input type="checkbox" name="token[read-logs]" value="true" /> Read logs</label>
            <label><input type="checkbox" name="token[act]" value="true" />
            Act: snooze, acknowledge, watch, route</label>
            <span class="end"><button class="btn primary" type="submit">Make a user token</button></span>
          </form>

          <div :if={!@full} class="est">
            <span>Let a script or an AI tool do everything you can do here.</span>
            <button class="btn sm" type="button" phx-click="full" id="full-open">Full control</button>
          </div>

          <form
            :if={@full}
            class="sure"
            phx-change="full_typed"
            phx-submit="full_token"
            id="full-form"
          >
            <h3>A token that can do everything</h3>

            <p>
              Whatever holds this token can do anything you can do in Dokkit, and nobody is asked first:
            </p>

            <ul>
              <li>Make and revoke keys, and add and remove people, owners included</li>

              <li>Change who is told, and silence an alert for good</li>

              <li>Accept what a scan found, change checks, and let services be restarted</li>

              <li>Read everything, log contents included</li>
            </ul>

            <p>
              An AI tool acts on what it reads, and it reads log lines and error text that your apps wrote. Give this only to a tool you would hand your own password.
            </p>

            <label>
              What it is for
              <input class="inp" name="full[label]" value={@full_form["label"]} required />
            </label>

            <label>
              <span>Type <b>{@host}</b> to confirm</span>
              <input
                class="inp"
                name="full[confirm]"
                value={@full_form["confirm"]}
                autocomplete="off"
                spellcheck="false"
              />
            </label>

            <label class="tick">
              <input
                type="checkbox"
                name="full[sure]"
                value="true"
                checked={@full_form["sure"] == "true"}
              /> I understand this token can remove people and keys, mine included.
            </label>

            <span class="end">
              <button class="btn" type="button" phx-click="full">Cancel</button>
              <button class="btn danger" type="submit" disabled={!@full_ok}>
                Make a full-control token
              </button>
            </span>
          </form>
        </div>

        <div :if={@archives != []} class="card">
          <h2>Archived logs<span class="cnt">{length(@archives)}</span></h2>

          <p class="lead">Months older than a year. One loaded back can be searched for a week.</p>

          <div
            :for={a <- @archives}
            class="li slim"
            style="--cols: minmax(0,1fr) 90px auto"
            id={"archive-#{a.name}"}
          >
            <span class="mono">{String.replace_prefix(a.name, "logs-", "")}</span>
            <span class="st">{Float.round(a.size / 1_048_576, 1)} MB</span>
            <span :if={a.back_until} class="tag">Loaded until {Calendar.strftime(
              a.back_until,
              "%b %-d"
            )}</span>
            <button
              :if={!a.back_until}
              class="btn sm"
              type="button"
              disabled={!@owner}
              phx-click="restore"
              phx-value-name={a.name}
            >
              Load back
            </button>
          </div>
        </div>

        <div class="card">
          <h2>Appearance</h2>

          <dl class="kv" id="look" phx-hook="Look" phx-update="ignore">
            <dt>Theme</dt>
            <dd>
              <div class="opts">
                <.look_opt key="theme" value="light" label="Light" sw="t-light" />
                <.look_opt key="theme" value="dark" label="Dark" sw="t-dark" />
                <.look_opt key="theme" value="" label="Follow this device" sw="" />
              </div>
            </dd>
            <dt>Dark base</dt>
            <dd>
              <div class="opts">
                <.look_opt
                  :for={{v, l} <- @bases}
                  key="base"
                  value={v}
                  label={l}
                  sw={"t-dark d-#{v}"}
                />
              </div>
              <span class="hint">Applies in dark</span>
            </dd>
            <dt>Accent</dt>
            <dd>
              <div class="opts">
                <button
                  :for={{v, l} <- @accents}
                  class="opt"
                  type="button"
                  data-look="accent"
                  data-value={v}
                  onclick={"dokkitLook('accent', '#{v}')"}
                >
                  <span class="sw ac"><i class={"t-light a-#{v}"}></i><i class={"t-dark a-#{v}"}></i></span>{l}
                </button>
              </div>
            </dd>
            <dt>Preview</dt>
            <dd>
              <div class="look-pv">
                <button class="btn primary" type="button">Primary</button>
                <button class="btn" type="button">Plain</button>
                <span class="tag">12</span>
                <a href="#look">A link</a>
                <span class="dots">
                  <b style="color: var(--ok)">Fine</b>
                  <b style="color: var(--warn)">Needs a look</b>
                  <b style="color: var(--bad)">Down</b>
                </span>
              </div>
              <span class="hint">
                Each choice applies as you click it and is kept in this browser. There is nothing to save.
              </span>
            </dd>
          </dl>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :key, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :sw, :string, required: true

  defp look_opt(assigns) do
    ~H"""
    <button
      class="opt"
      type="button"
      data-look={@key}
      data-value={@value}
      onclick={"dokkitLook('#{@key}', '#{@value}')"}
    >
      <span class={["sw", @sw]}></span>{@label}
    </button>
    """
  end

  defp holder(%{machine: %{name: name}}), do: name
  defp holder(%{service: %{name: name}}), do: name
  defp holder(_), do: "Unnamed"
end
