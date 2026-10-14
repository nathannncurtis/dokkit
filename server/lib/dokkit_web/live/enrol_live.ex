defmodule DokkitWeb.EnrolLive do
  use DokkitWeb, :live_view
  alias Dokkit.{Key, Keys, Repo}

  @tick 5_000
  @cols "--cols:minmax(0,1.4fr) 110px 150px 150px 96px;--minw:640px"

  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick)

    {:ok,
     assign(socket,
       page_title: "Add a machine",
       token: nil,
       key: nil,
       machine: nil,
       mode: "service",
       name: "",
       now: DateTime.utc_now(),
       waiting: Keys.waiting()
     )}
  end

  def handle_info(:issues_changed, socket), do: {:noreply, socket}

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick)
    {:noreply, refresh(socket)}
  end

  def handle_event("form", params, socket), do: {:noreply, shape(socket, params)}

  def handle_event("token", params, socket) do
    if socket.assigns.current_user.role == :owner do
      socket = shape(socket, params)
      name = socket.assigns.name

      {token, key} =
        Keys.mint_enrol(
          if(name == "", do: "Made by #{socket.assigns.current_user.name}", else: name)
        )

      {:noreply, refresh(assign(socket, token: token, key: key, machine: nil))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    if socket.assigns.current_user.role == :owner and
         Enum.any?(socket.assigns.waiting, &(&1.id == id)),
       do: Keys.revoke(id)

    {:noreply, refresh(socket)}
  end

  defp shape(socket, params),
    do:
      assign(socket,
        mode: if(params["mode"] == "login", do: "login", else: "service"),
        name: String.trim(params["name"] || "")
      )

  defp refresh(socket) do
    %{key: key, machine: machine} = socket.assigns
    key = key && Repo.get(Key, key.id)

    assign(socket,
      key: key,
      machine: machine || (key && Keys.arrived(key)),
      waiting: Keys.waiting(),
      now: DateTime.utc_now()
    )
  end

  defp lines(token, mode) do
    [
      "dokkit enrol #{Dokkit.Certificate.url()} #{token}#{pin()}",
      if(mode == "service", do: "dokkit service install", else: "dokkit watch")
    ]
  end

  # The fingerprint of the certificate this server serves, when it serves one itself.
  defp pin do
    with false <- Dokkit.Certificate.trusted_address?(),
         path when is_binary(path) <- Application.get_env(:dokkit, :cert),
         {:ok, pem} <- File.read(path),
         [{:Certificate, der, _} | _] <- :public_key.pem_decode(pem) do
      " sha256:" <> Base.encode16(:crypto.hash(:sha256, der), case: :lower)
    else
      _ -> ""
    end
  end

  def render(assigns) do
    assigns = assign(assigns, cols: @cols)

    ~H"""
    <Layouts.app active={:all} shell={@shell} user={@current_user}>
      <div class="crumb">
        <.link navigate={~p"/all"}>Everything</.link><.ic name="caret-right" /><span>Add a machine</span>
      </div>
      <div class="head">
        <h1 tabindex="-1">Add a machine</h1>
      </div>
      <div class="body set">
        <div class="card">
          <h2>1. Get the program on the machine</h2>
          <p class="lead">
            Skip this if the machine already has the dokkit program. On Linux or macOS:
          </p>
          <pre class="logbox" id="get-unix">curl -fsSL https://dokkit.dev/get.sh | sh</pre>
          <p class="lead">On Windows, in PowerShell:</p>
          <pre class="logbox" id="get-windows">irm https://dokkit.dev/get.ps1 | iex</pre>
        </div>

        <div class="card">
          <h2>2. Make a one-use token for it</h2>
          <p :if={@current_user.role != :owner} class="lead">
            Only the owner can make a token.
          </p>
          <form phx-submit="token" phx-change="form" id="token-form">
            <div class="form">
              <label>
                Machine name (optional)
                <input
                  class="inp"
                  name="name"
                  value={@name}
                  placeholder="Its hostname"
                  disabled={@current_user.role != :owner}
                />
              </label>
              <label>
                How it will run
                <span>
                  <input
                    type="radio"
                    name="mode"
                    value="service"
                    checked={@mode == "service"}
                    disabled={@current_user.role != :owner}
                  /> As a service: starts with the machine and keeps running
                </span>
                <span>
                  <input
                    type="radio"
                    name="mode"
                    value="login"
                    checked={@mode == "login"}
                    disabled={@current_user.role != :owner}
                  /> In a terminal, while someone is signed in
                </span>
              </label>
            </div>
            <div class="foot">
              <span>The token works once and runs out in 4 hours.</span>
              <span class="end">
                <button class="btn primary" type="submit" disabled={@current_user.role != :owner}>
                  {if @token, do: "Make another token", else: "Make a token"}
                </button>
              </span>
            </div>
          </form>
        </div>

        <div :if={@token} class="card" id="enrol-card">
          <h2>3. Paste this on the machine</h2>
          <span hidden id="enrol-commands">{Enum.join(lines(@token, @mode), "\n")}</span>
          <div :for={{line, n} <- Enum.with_index(lines(@token, @mode), 1)} class="once">
            <pre class="mono" id={"enrol-line-#{n}"} style="margin: 0; white-space: pre-wrap">{line}</pre>
            <button class="btn sm" type="button" data-copy={"#enrol-line-#{n}"}>Copy</button>
          </div>
          <div class="foot">
            <span class="end">
              <button class="btn sm" type="button" data-copy="#enrol-commands">Copy both</button>
            </span>
          </div>
          <p :if={@mode == "service"} class="lead">
            Run both lines in a terminal opened as administrator, or with <code>sudo</code>
            on Linux; installing the service needs that once. To have it read a folder of
            <code>dokkit.toml</code>
            files, run <code>dokkit folder add &lt;folder&gt;</code>
            there as well; the service picks the list up within a minute.
          </p>
          <p :if={@mode == "login"} class="lead">
            The second line stays running. Leave that terminal open, or start it again after a restart.
          </p>
          <div class="foot" id="enrol-state">
            <span :if={@machine}>
              <.ic name="check-circle" /> Token <span class="mono">{@key.hint}</span>
              became <.link navigate={~p"/machines/#{@machine.id}"}>{@machine.name}</.link>
              and is spent. It reports once a minute; three minutes of silence opens an issue.
            </span>
            <span :if={!@machine and @key.revoked_at}>
              The token was revoked. Make another one above.
            </span>
            <span :if={!@machine and !@key.revoked_at and Keys.left(@key, @now)}>
              Waiting for the machine. The token runs out in {Keys.left(@key, @now)}, and it is shown only now.
            </span>
            <span :if={!@machine and !@key.revoked_at and !Keys.left(@key, @now)}>
              The token has run out. Make another one above.
            </span>
          </div>
        </div>

        <div :if={@current_user.role == :owner and @waiting != []} class="card" id="waiting">
          <h2>Tokens waiting<span class="cnt">{length(@waiting)}</span></h2>
          <p class="lead">Made and not used yet. Revoke one that is no longer wanted.</p>
          <div class="lh cols-key" style={@cols}>
            <span>Token</span><span>For</span><span>Made</span><span>Time left</span><span></span>
          </div>
          <div :for={k <- @waiting} class="li slim cols-key" style={@cols} id={"waiting-#{k.id}"}>
            <div>
              <div class="ti"><span>{k.label || "Unnamed"}</span></div>
              <div class="sub mono">{k.hint}</div>
            </div>
            <span class="tag">Enrolment token</span>
            <span class="mono">{at(k.inserted_at)}</span>
            <span class="mono left">{Keys.left(k, @now)}</span>
            <button
              class="btn sm"
              type="button"
              phx-click="revoke"
              phx-value-id={k.id}
              data-confirm="Revoke this token? The machine it was made for cannot use it."
            >
              Revoke
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
