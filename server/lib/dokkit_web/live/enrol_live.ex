defmodule DokkitWeb.EnrolLive do
  use DokkitWeb, :live_view
  import Ecto.Query
  alias Dokkit.{Key, Keys, Machine, Repo}

  @life 4 * 3600
  @tick 5_000

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
       now: DateTime.utc_now()
     )}
  end

  def handle_info(:issues_changed, socket), do: {:noreply, socket}

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick)
    {:noreply, assign(socket, now: DateTime.utc_now(), machine: arrived(socket.assigns))}
  end

  def handle_event("form", params, socket), do: {:noreply, shape(socket, params)}

  def handle_event("token", params, socket) do
    if socket.assigns.current_user.role == :owner do
      socket = shape(socket, params)
      name = socket.assigns.name

      {token, key} =
        Keys.mint(:enrol, %{
          expires_at: DateTime.add(DateTime.utc_now(), @life),
          label: if(name == "", do: "Made by #{socket.assigns.current_user.name}", else: name)
        })

      {:noreply, assign(socket, token: token, key: key, machine: nil, now: DateTime.utc_now())}
    else
      {:noreply, socket}
    end
  end

  defp shape(socket, params),
    do:
      assign(socket,
        mode: if(params["mode"] == "login", do: "login", else: "service"),
        name: String.trim(params["name"] || "")
      )

  defp arrived(%{key: %Key{} = key, machine: nil}) do
    with %Key{used_at: %DateTime{} = used} <- Repo.get(Key, key.id) do
      Repo.one(
        from m in Machine,
          where: m.kind == :enrolled and m.updated_at >= ^used,
          order_by: [desc: m.updated_at],
          limit: 1
      )
    end
  end

  defp arrived(%{machine: machine}), do: machine

  defp left(key, now) do
    s = DateTime.diff(key.expires_at, now)

    cond do
      s <= 0 -> nil
      s >= 3600 -> "#{div(s, 3600)} h #{div(rem(s, 3600), 60)} min"
      true -> "#{div(s, 60) + 1} min"
    end
  end

  defp commands(token, mode) do
    "dokkit enrol #{Dokkit.Certificate.url()} #{token}#{pin()}\n" <>
      if(mode == "service", do: "dokkit service install", else: "dokkit watch")
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
          <div class="once">
            <pre class="mono" id="enrol-commands" style="margin: 0; white-space: pre-wrap">{commands(@token, @mode)}</pre>
            <button class="btn sm" type="button" data-copy="#enrol-commands">Copy</button>
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
              <.ic name="check-circle" />
              <.link navigate={~p"/all#m-#{@machine.id}"}>{@machine.name}</.link>
              is enrolled. It reports once a minute; three minutes of silence opens an issue.
            </span>
            <span :if={!@machine and left(@key, @now)}>
              Waiting for the machine. The token runs out in {left(@key, @now)}, and it is shown only now.
            </span>
            <span :if={!@machine and !left(@key, @now)}>
              The token has run out. Make another one above.
            </span>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
