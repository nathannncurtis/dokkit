defmodule DokkitWeb.AlertsLive do
  use DokkitWeb, :live_view
  alias Dokkit.Alerts

  @push [{"ntfy", "ntfy"}, {"Pushover", "pushover"}, {"PagerDuty low urgency", "pagerduty"}]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Alerts",
       config: Alerts.config(),
       rules: Alerts.rules(),
       suggestions: Alerts.suggestions(),
       saved: false,
       error: nil,
       tests: %{}
     )}
  end

  def handle_info(:issues_changed, socket), do: {:noreply, socket}

  def handle_event("save", %{"alerts" => params}, socket) do
    cond do
      !owner?(socket) ->
        {:noreply, socket}

      error = bad_address(params) ->
        {:noreply, assign(socket, error: error, saved: false)}

      true ->
        {:noreply, assign(socket, config: Alerts.save(params), saved: true, error: nil)}
    end
  end

  def handle_event("changed", _, socket), do: {:noreply, assign(socket, saved: false, error: nil)}

  def handle_event("rule", params, socket) do
    if owner?(socket) do
      case params do
        %{"rule" => rule} -> Alerts.add_rule(rule)
        %{"toggle" => id} -> Alerts.toggle_rule(id)
        %{"remove" => id} -> Alerts.delete_rule(id)
      end
    end

    {:noreply, assign(socket, rules: Alerts.rules())}
  end

  def handle_event("suggestion", params, socket) do
    if owner?(socket) do
      case params do
        %{"accept" => id} -> Alerts.accept_suggestion(id)
        %{"dismiss" => id} -> Alerts.dismiss_suggestion(id)
      end
    end

    {:noreply, assign(socket, suggestions: Alerts.suggestions())}
  end

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

  defp bad_address(params) do
    Enum.find_value(~w(ntfy_url webhook_url heartbeat_url), fn k ->
      url = String.trim(params[k] || "")

      with true <- url != "", {:error, why} <- Alerts.check_url(url) do
        "#{String.replace(k, "_url", "")}: #{why}"
      else
        _ -> nil
      end
    end)
  end

  defp owner?(socket), do: socket.assigns.current_user.role == :owner

  def render(assigns) do
    assigns =
      assign(assigns,
        channels: Alerts.channels(),
        kinds: Alerts.rule_kinds(),
        states: Alerts.rule_states(),
        push: @push,
        owner: assigns.current_user.role == :owner
      )

    ~H"""
    <Layouts.app active={:alerts} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">Alerts</h1>
      </div>

      <div :if={@suggestions != []} class="body set" style="padding-bottom: 0">
        <div class="card">
          <h2>Suggestions<span class="cnt">{length(@suggestions)}</span></h2>

          <div
            :for={i <- @suggestions}
            class="li slim"
            style="--cols: minmax(0,1fr) auto auto"
            id={"suggestion-#{i.id}"}
          >
            <span>
              {i.service.name} has needed a look {i.count} times this month and is snoozed. Send it to the daily digest instead?
            </span>

            <button
              class="btn sm"
              type="button"
              disabled={!@owner}
              phx-click="suggestion"
              phx-value-accept={i.id}
            >
              Send to the digest
            </button>

            <button
              class="btn sm"
              type="button"
              disabled={!@owner}
              phx-click="suggestion"
              phx-value-dismiss={i.id}
            >
              Dismiss
            </button>
          </div>
        </div>
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
                /> <.send_test channel="push" tests={@tests} />
                <span class="hint">A quiet notification on your phone, for what should be seen today.</span>
              </dd>

              <dt>ntfy</dt>

              <dd>
                <input
                  class="inp"
                  style="flex: 1 1 260px"
                  name="alerts[ntfy_url]"
                  value={@owner && @config["ntfy_url"]}
                  placeholder="https://ntfy.sh/your-topic"
                  aria-label="ntfy topic address"
                />
                <.secret
                  name="ntfy_token"
                  config={@config}
                  label="Access token, if the topic needs one"
                /> <span class="hint">An https address.</span>
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
                  value={@owner && @config["webhook_url"]}
                  placeholder="https://example.com/hook"
                  aria-label="Webhook address"
                /> <.send_test channel="webhook" tests={@tests} />
                <span class="hint">
                  An https address. A JSON request when an issue opens and another when it closes.
                </span>
              </dd>

              <dt>Mail server</dt>

              <dd>
                <input
                  :for={
                    {name, label, width} <- [
                      {"smtp_host", "Mail server, such as smtp.example.com", 240},
                      {"smtp_port", "Port, 587 unless told otherwise", 90},
                      {"smtp_user", "User name", 180}
                    ]
                  }
                  class="inp"
                  style={"flex: 1 1 #{width}px"}
                  name={"alerts[#{name}]"}
                  value={(@owner || name != "smtp_user") && @config[name]}
                  placeholder={label}
                  aria-label={label}
                /> <.secret name="smtp_password" config={@config} label="Password" />
                <input
                  class="inp"
                  style="flex: 1 1 240px"
                  name="alerts[mail_from]"
                  value={@config["mail_from"]}
                  placeholder="Sent from, such as dokkit@example.com"
                  aria-label="Sent from"
                /> <span class="hint">Used for email, text and the daily digest.</span>
              </dd>

              <dt>Email</dt>

              <dd>
                <input
                  class="inp"
                  style="flex: 1 1 260px"
                  name="alerts[email_to]"
                  value={@config["email_to"]}
                  placeholder="you@example.com"
                  aria-label="Email goes to"
                /> <.send_test channel="email" tests={@tests} />
                <span class="hint">More than one address, with commas between them.</span>
              </dd>

              <dt>Text</dt>

              <dd>
                <input
                  class="inp"
                  style="flex: 1 1 260px"
                  name="alerts[text_to]"
                  value={@config["text_to"]}
                  placeholder="5551234567@your-carrier.example"
                  aria-label="Text goes to"
                /> <.send_test channel="text" tests={@tests} />
                <span class="hint">An address that turns a mail into a text message.</span>
              </dd>

              <dt>A machine's disk</dt>

              <dd>
                <input
                  class="inp"
                  style="flex: 0 1 90px"
                  name="alerts[disk_limit]"
                  value={@config["disk_limit"]}
                  inputmode="numeric"
                  aria-label="Disk percent used that needs a look"
                />
                <span class="hint">Percent used, on any disk, that needs a look. Blank switches it off.</span>
              </dd>

              <dt>A machine's memory</dt>

              <dd>
                <input
                  class="inp"
                  style="flex: 0 1 90px"
                  name="alerts[memory_limit]"
                  value={@config["memory_limit"]}
                  inputmode="numeric"
                  aria-label="Memory percent used that needs a look"
                />
                <span class="hint">Percent used that needs a look, three minutes running. Blank switches it off.</span>
              </dd>

              <dt>Outside heartbeat</dt>

              <dd>
                <input
                  class="inp"
                  style="flex: 1 1 260px"
                  name="alerts[heartbeat_url]"
                  value={@owner && @config["heartbeat_url"]}
                  placeholder="https://example.com/ping/your-check"
                  aria-label="Outside heartbeat address"
                />
                <span class="hint">
                  An https address. Dokkit calls it every minute. Point it at a service that alerts when the calls stop, because Dokkit cannot tell anyone that it is down.
                </span>
              </dd>

              <dt>Daily digest</dt>

              <dd>
                <input
                  class="inp mono"
                  style="width: 90px"
                  name="alerts[digest_at]"
                  value={@config["digest_at"]}
                  placeholder="07:00"
                  aria-label="Digest time, UTC"
                />
                <span class="hint">
                  One email a day at this time, UTC: what opened without paging, new errors, and numbers close to a limit. A day with nothing to say sends nothing.
                </span>
              </dd>
            </dl>

            <div class="foot">
              <span :if={!@owner}>Only the owner can change these.</span>
              <span :if={@saved} role="status">Saved.</span>
              <span :if={@error} role="alert">{@error}</span>
              <span class="end"><button class="btn primary" type="submit">Save</button></span>
            </div>
          </div>
        </fieldset>
      </form>

      <form class="body set" phx-submit="rule" id="rule-form" style="padding-top: 0">
        <fieldset disabled={!@owner} style="display: contents">
          <div class="card">
            <h2>Rules<span :if={@rules != []} class="cnt">{length(@rules)}</span></h2>

            <p :if={@rules == []} class="lead">
              No rules. Every issue follows the two choices under Who is told, unless its service says otherwise.
            </p>

            <div
              :for={r <- @rules}
              class="li slim"
              style="--cols: minmax(0,1fr) auto auto"
              id={"rule-#{r["id"]}"}
            >
              <span class={!r["on"] && "mute"}>{describe(r, @kinds, @states, @channels)}</span>
              <button class="btn sm" type="button" phx-click="rule" phx-value-toggle={r["id"]}>
                {if r["on"], do: "Switch off", else: "Switch on"}
              </button>

              <button class="btn sm" type="button" phx-click="rule" phx-value-remove={r["id"]}>
                Remove
              </button>
            </div>

            <dl class="kv">
              <dt>New rule</dt>

              <dd>
                <span :for={{field, options} <- [{"kind", @kinds}, {"state", @states}]} class="dd">
                  <select class="inp" name={"rule[#{field}]"} aria-label={"Rule " <> field}>
                    <option :for={{text, value} <- options} value={value}>{text}</option>
                  </select>
                  <i class="ph ph-caret-down" aria-hidden="true"></i>
                </span>

                <input
                  class="inp"
                  style="flex: 1 1 160px"
                  name="rule[machine]"
                  placeholder="On machine (blank for any)"
                  aria-label="On machine"
                />
                <span class="dd">
                  <select class="inp" name="rule[channel]" aria-label="Rule channel">
                    <option :for={{text, value} <- @channels} value={value}>{text}</option>
                  </select>
                  <i class="ph ph-caret-down" aria-hidden="true"></i>
                </span>
                <button class="btn" type="submit">Add the rule</button>
                <span class="hint">
                  The first rule that fits an issue decides its channel. A service's own routing comes first.
                </span>
              </dd>
            </dl>
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

  defp describe(rule, kinds, states, channels) do
    on = if rule["machine"] == "", do: "", else: " on #{rule["machine"]}"

    "When #{String.downcase(name(kinds, rule["kind"]))} #{name(states, rule["state"])}#{on}: " <>
      name(channels, rule["channel"])
  end

  defp name(options, value),
    do: Enum.find_value(options, "", fn {text, v} -> v == value && text end)

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
