defmodule DokkitWeb.AlertsLive do
  use DokkitWeb, :live_view
  alias Dokkit.Alerts

  @secrets Alerts.secrets()
  @push [{"ntfy", "ntfy"}, {"Pushover", "pushover"}, {"PagerDuty low urgency", "pagerduty"}]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Alerts",
       config: Alerts.config(),
       macs: Alerts.macs(),
       rules: Alerts.rules(),
       suggestions: Alerts.suggestions(),
       saved: false,
       note: nil,
       error: nil,
       typed: %{},
       waiting: false,
       tests: %{}
     )}
  end

  def handle_info(:issues_changed, socket), do: {:noreply, socket}

  def handle_event("save", %{"alerts" => params}, socket) do
    with true <- owner?(socket) do
      # A secret field left empty keeps the stored secret; its Clear box empties it.
      kept =
        Enum.reduce(@secrets, params, fn k, acc ->
          cond do
            acc["clear_" <> k] == "true" -> Map.put(acc, k, "")
            acc[k] in [nil, ""] -> Map.delete(acc, k)
            true -> acc
          end
        end)

      case Alerts.update(kept) do
        {:ok, config, note} ->
          {:noreply,
           assign(socket, config: config, typed: %{}, saved: true, error: nil, note: note)}

        {:error, error} ->
          {:noreply, typed(socket, params, error)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("changed", %{"alerts" => params}, socket),
    do: {:noreply, typed(socket, params, nil)}

  def handle_event("changed", _, socket),
    do: {:noreply, assign(socket, saved: false, error: nil, note: nil)}

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

  def handle_event("test", %{"channel" => "imessage"}, socket) do
    if owner?(socket) and not socket.assigns.waiting do
      user = socket.assigns.current_user.id

      {:noreply,
       socket
       |> assign(
         waiting: true,
         tests:
           Map.put(socket.assigns.tests, "imessage", {:wait, "Waiting for the Mac to answer."})
       )
       |> start_async(:imessage, fn ->
         DokkitWeb.ApiController.try_alert(%{"channel" => "imessage"}, user)
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("test", %{"channel" => channel}, socket) do
    if owner?(socket) and Alerts.sends?(channel) do
      {:noreply,
       assign(socket, tests: Map.put(socket.assigns.tests, channel, test_result(channel, socket)))}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:imessage, {:ok, answer}, socket),
    do:
      {:noreply,
       assign(socket,
         waiting: false,
         tests: Map.put(socket.assigns.tests, "imessage", answer(answer))
       )}

  def handle_async(:imessage, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket,
         waiting: false,
         tests: Map.put(socket.assigns.tests, "imessage", {:error, "The test did not finish."})
       )}

  defp test_result(channel, socket),
    do:
      answer(
        DokkitWeb.ApiController.try_alert(%{"channel" => channel}, socket.assigns.current_user.id)
      )

  defp answer(%{ok: true}), do: {:ok, "Sent. Check that it arrived."}
  defp answer({:error, _, text}), do: {:error, text}

  defp no_mac?(config, key),
    do: config[key] == "imessage" and config["imessage_machine"] in [nil, ""]

  defp rule_no_mac?(rules, config),
    do:
      Enum.any?(rules, &(&1["on"] and &1["channel"] == "imessage")) and
        config["imessage_machine"] in [nil, ""]

  # Keep what was typed, so a page update does not put the saved values back over it.
  defp typed(socket, params, error) do
    {secrets, plain} = Map.split(params, @secrets)

    assign(socket,
      config: Map.merge(socket.assigns.config, plain),
      typed: secrets,
      saved: false,
      note: nil,
      error: error
    )
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
            <h2>PagerDuty</h2>
            
            <dl class="kv">
              <dt>Page</dt>
              
              <dd>
                <.secret
                  typed={@typed}
                  name="pagerduty_key"
                  config={@config}
                  label="PagerDuty routing key"
                /> <.send_test channel="page" tests={@tests} />
                <span class="hint">
                  Through PagerDuty, for what cannot wait until morning. The key is the integration key of an Events API v2 integration. The page is resolved when the issue closes.
                </span>
              </dd>
            </dl>
          </div>
          
          <div class="card">
            <h2>Push</h2>
            
            <dl class="kv">
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
                <.secret
                  typed={@typed}
                  name="pushover_token"
                  config={@config}
                  label="Application token"
                /> <.secret typed={@typed} name="pushover_user" config={@config} label="User key" />
              </dd>
            </dl>
          </div>
          
          <div class="card">
            <h2>Email</h2>
            
            <dl class="kv">
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
                /> <.secret typed={@typed} name="smtp_password" config={@config} label="Password" />
                <input
                  class="inp"
                  style="flex: 1 1 240px"
                  name="alerts[mail_from]"
                  value={@config["mail_from"]}
                  placeholder="Sent from, such as dokkit@example.com"
                  aria-label="Sent from"
                /> <span class="hint">Used for email and the daily digest.</span>
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
            </dl>
          </div>
          
          <div class="card" id="imessage">
            <h2>iMessage</h2>
            
            <dl class="kv">
              <dt>Sent from</dt>
              
              <dd>
                <span :if={@macs != []} class="dd wide">
                  <select
                    class="inp"
                    name="alerts[imessage_machine]"
                    aria-label="The Mac that sends iMessages"
                  >
                    <option value="">No Mac chosen</option>
                    
                    <option
                      :for={m <- @macs}
                      value={m.id}
                      selected={m.id == @config["imessage_machine"]}
                    >
                      {m.name}
                    </option>
                  </select>
                   <i class="ph ph-caret-down" aria-hidden="true"></i>
                </span>
                
                <span :if={@macs == []} class="hint">
                  No Mac is enrolled. iMessage goes out through a Mac that runs the program and is signed in to Messages.
                </span>
                
                <span :if={@macs != [] and @config["imessage_machine"] in [nil, ""]} class="hint bad">
                  The iMessage channel will not send until a Mac is chosen.
                </span>
              </dd>
              
              <dt>Goes to</dt>
              
              <dd>
                <input
                  class="inp"
                  style="flex: 1 1 260px"
                  name="alerts[imessage_to]"
                  value={@config["imessage_to"]}
                  placeholder="+15555550100, you@example.com"
                  aria-label="iMessage goes to"
                /> <.send_test channel="imessage" tests={@tests} />
                <span class="hint">
                  Phone numbers or email addresses, with commas between them. Run
                  <code>dokkit imessage on</code>
                  on that Mac so it may send; macOS asks once on its screen.
                </span>
              </dd>
            </dl>
          </div>
          
          <div class="card" id="sms">
            <h2>SMS</h2>
            
            <dl class="kv">
              <dt>Twilio account</dt>
              
              <dd>
                <input
                  class="inp"
                  style="flex: 1 1 200px"
                  name="alerts[twilio_sid]"
                  value={@owner && @config["twilio_sid"]}
                  placeholder="Account SID"
                  aria-label="Twilio account SID"
                /> <.secret typed={@typed} name="twilio_token" config={@config} label="Auth token" />
                <input
                  class="inp"
                  style="flex: 1 1 160px"
                  name="alerts[twilio_from]"
                  value={@config["twilio_from"]}
                  placeholder="Sent from, such as +15555550100"
                  aria-label="Twilio number the text is sent from"
                />
              </dd>
              
              <dt>Goes to</dt>
              
              <dd>
                <input
                  class="inp"
                  style="flex: 1 1 260px"
                  name="alerts[sms_to]"
                  value={@config["sms_to"]}
                  placeholder="+15555550100, +15555550101"
                  aria-label="SMS goes to"
                /> <.send_test channel="sms" tests={@tests} />
                <span class="hint">Phone numbers, with commas between them.</span>
              </dd>
            </dl>
          </div>
          
          <div class="card">
            <h2>Webhook</h2>
            
            <dl class="kv">
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
            </dl>
          </div>
          
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
                <span :if={no_mac?(@config, "down")} class="hint bad">
                  iMessage will not send until a Mac is chosen above.
                </span>
              </dd>
              
              <dt>When something is struggling</dt>
              
              <dd>
                <.pick
                  name="degraded"
                  value={@config["degraded"]}
                  options={@channels}
                  label="When something is struggling"
                />
                <span :if={no_mac?(@config, "degraded")} class="hint bad">
                  iMessage will not send until a Mac is chosen above.
                </span>
                
                <span class="hint">
                  An issue alerts once, when it opens. If it recovers and fails again inside 30 minutes, that is the same issue and it stays quiet.
                </span>
              </dd>
            </dl>
          </div>
          
          <div class="card">
            <h2>Limits and night</h2>
            
            <dl class="kv">
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
              
              <dt>Night</dt>
              
              <dd>
                <input
                  class="inp mono"
                  style="width: 70px"
                  name="alerts[night_from]"
                  value={@config["night_from"]}
                  inputmode="numeric"
                  aria-label="Night starts at hour"
                />
                <input
                  class="inp mono"
                  style="width: 70px"
                  name="alerts[night_to]"
                  value={@config["night_to"]}
                  inputmode="numeric"
                  aria-label="Night ends at hour"
                />
                <input
                  class="inp mono"
                  style="width: 70px"
                  name="alerts[night_offset]"
                  value={@config["night_offset"]}
                  inputmode="numeric"
                  aria-label="Hours from UTC"
                />
                <span class="hint">
                  Start hour, end hour and hours from UTC, for example 22, 7 and -5. A service set not to wake you at night holds its alerts until the night ends.
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
              <span :if={@saved} role="status">Saved. {@note}</span>
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
            
            <p :if={rule_no_mac?(@rules, @config)} class="lead bad">
              A rule sends by iMessage, and it will not send until a Mac is chosen above.
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
  attr :typed, :map, default: %{}
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
      value={@typed[@name]}
      placeholder={if @set, do: "#{@label}: kept, type to replace", else: @label}
    />
    <label :if={@set} class="hint">
      <input type="checkbox" name={"alerts[clear_#{@name}]"} value="true" /> Clear
    </label>
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
