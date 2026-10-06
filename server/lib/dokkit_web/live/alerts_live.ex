defmodule DokkitWeb.AlertsLive do
  use DokkitWeb, :live_view
  alias Dokkit.Alerts

  @push [{"ntfy", "ntfy"}, {"Pushover", "pushover"}, {"PagerDuty low urgency", "pagerduty"}]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Alerts", config: Alerts.config(), saved: false, tests: %{})}
  end

  def handle_info(:issues_changed, socket), do: {:noreply, socket}

  def handle_event("save", %{"alerts" => params}, socket) do
    if owner?(socket),
      do: {:noreply, assign(socket, config: Alerts.save(params), saved: true)},
      else: {:noreply, socket}
  end

  def handle_event("changed", _, socket), do: {:noreply, assign(socket, saved: false)}

  def handle_event("test", %{"channel" => channel}, socket) do
    if owner?(socket) and Alerts.sends?(channel) do
      result =
        case Alerts.test(channel) do
          :ok -> {:ok, "Sent. Check that it arrived."}
          {:error, text} -> {:error, text}
        end

      {:noreply, assign(socket, tests: Map.put(socket.assigns.tests, channel, result))}
    else
      {:noreply, socket}
    end
  end

  defp owner?(socket), do: socket.assigns.current_user.role == :owner

  def render(assigns) do
    assigns =
      assign(assigns,
        channels: Alerts.channels(),
        push: @push,
        owner: assigns.current_user.role == :owner
      )

    ~H"""
    <Layouts.app active={:alerts} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">Alerts</h1>
      </div>
      <form class="body set" phx-submit="save" phx-change="changed" id="alerts-form">
        <fieldset disabled={!@owner} style="display: contents">
          <div class="card">
            <h2>Who is told</h2>
            <dl class="kv">
              <dt>When something stops</dt>
              <dd>
                <.pick
                  name="down"
                  value={@config["down"]}
                  options={@channels}
                  label="When something stops"
                />
              </dd>
              <dt>When something is struggling</dt>
              <dd>
                <.pick
                  name="degraded"
                  value={@config["degraded"]}
                  options={@channels}
                  label="When something is struggling"
                />
                <span class="hint">
                  An issue alerts once, when it opens. If it recovers and fails again inside 30 minutes, that is the same issue and it stays quiet.
                </span>
              </dd>
            </dl>
          </div>
          <div class="card">
            <h2>Channels</h2>
            <dl class="kv">
              <dt>Page</dt>
              <dd>
                <.secret name="pagerduty_key" config={@config} label="PagerDuty routing key" />
                <.send_test channel="page" tests={@tests} />
                <span class="hint">
                  Through PagerDuty, for what cannot wait until morning. The key is the integration key of an Events API v2 integration. The page is resolved when the issue closes.
                </span>
              </dd>
              <dt>Push</dt>
              <dd>
                <.pick
                  name="push_with"
                  value={@config["push_with"]}
                  options={@push}
                  label="Push goes through"
                />
                <.send_test channel="push" tests={@tests} />
                <span class="hint">A quiet notification on your phone, for what should be seen today.</span>
              </dd>
              <dt>ntfy</dt>
              <dd>
                <input
                  class="inp"
                  style="flex: 1 1 260px"
                  name="alerts[ntfy_url]"
                  value={@config["ntfy_url"]}
                  placeholder="https://ntfy.sh/your-topic"
                  aria-label="ntfy topic address"
                />
                <.secret
                  name="ntfy_token"
                  config={@config}
                  label="Access token, if the topic needs one"
                />
              </dd>
              <dt>Pushover</dt>
              <dd>
                <.secret name="pushover_token" config={@config} label="Application token" />
                <.secret name="pushover_user" config={@config} label="User key" />
              </dd>
              <dt>Webhook</dt>
              <dd>
                <input
                  class="inp"
                  style="flex: 1 1 260px"
                  name="alerts[webhook_url]"
                  value={@config["webhook_url"]}
                  placeholder="https://example.com/hook"
                  aria-label="Webhook address"
                />
                <.send_test channel="webhook" tests={@tests} />
                <span class="hint">A JSON request when an issue opens and another when it closes.</span>
              </dd>
            </dl>
            <div class="foot">
              <span :if={!@owner}>Only the owner can change these.</span>
              <span :if={@saved} role="status">Saved.</span>
              <span class="end"><button class="btn primary" type="submit">Save</button></span>
            </div>
          </div>
        </fieldset>
      </form>
    </Layouts.app>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :options, :list, required: true
  attr :label, :string, required: true

  defp pick(assigns) do
    ~H"""
    <span class="dd wide">
      <select class="inp" name={"alerts[#{@name}]"} aria-label={@label}>
        <option :for={{text, value} <- @options} value={value} selected={value == @value}>
          {text}
        </option>
      </select>
      <i class="ph ph-caret-down" aria-hidden="true"></i>
    </span>
    """
  end

  attr :name, :string, required: true
  attr :config, :map, required: true
  attr :label, :string, required: true

  defp secret(assigns) do
    assigns = assign(assigns, set: assigns.config[assigns.name] not in [nil, ""])

    ~H"""
    <input
      class="inp"
      style="flex: 1 1 200px"
      type="password"
      name={"alerts[#{@name}]"}
      autocomplete="off"
      aria-label={@label}
      placeholder={if @set, do: "#{@label}: kept, type to replace", else: @label}
    />
    """
  end

  attr :channel, :string, required: true
  attr :tests, :map, required: true

  defp send_test(assigns) do
    assigns = assign(assigns, result: assigns.tests[assigns.channel])

    ~H"""
    <button
      class="btn"
      type="button"
      phx-click="test"
      phx-value-channel={@channel}
      phx-disable-with="Sending"
    >
      Send a test
    </button>
    <span :if={@result} class={["hint", elem(@result, 0) == :error && "bad"]} role="status">{elem(
      @result,
      1
    )}</span>
    """
  end
end
