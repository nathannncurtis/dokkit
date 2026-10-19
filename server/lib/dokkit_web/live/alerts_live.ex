defmodule DokkitWeb.AlertsLive do
  use DokkitWeb, :live_view
  alias Dokkit.{Alerts, People}
  alias DokkitWeb.{ChannelPick, WhoPick}

  @secrets Alerts.secrets()
  @push [{"ntfy", "ntfy"}, {"Pushover", "pushover"}, {"PagerDuty low urgency", "pagerduty"}]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Alerts",
       config: Alerts.config(),
       imessage: Alerts.imessage_status(),
       people: People.list(),
       who: People.audience_rows(),
       macs: Alerts.macs(),
       rules: Alerts.rules(),
       suggestions: Alerts.suggestions(),
       saved: false,
       where: nil,
       note: nil,
       error: nil,
       typed: %{},
       waiting: false,
       tests: %{}
     )}
  end

  def handle_info(:issues_changed, socket), do: {:noreply, socket}

  @blocks %{
    "page" => "pagerduty",
    "push" => "push",
    "email" => "email",
    "imessage" => "imessage",
    "sms" => "sms",
    "webhook" => "webhook"
  }

  def handle_event("save", %{"alerts" => params} = sent, socket) do
    test = sent["test"]
    socket = assign(socket, where: sent["at"] || @blocks[test] || "limits")

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

      case Alerts.update(alone(kept, socket.assigns.config)) do
        {:ok, config, note} ->
          socket =
            assign(socket,
              config: config,
              imessage: Alerts.imessage_status(config),
              typed: %{},
              saved: true,
              error: nil,
              note: note
            )

          if test,
            do: handle_event("test", %{"channel" => test}, socket),
            else: {:noreply, socket}

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
        %{"rule" => rule} -> add_rule(Map.update(rule, "channel", [], &Alerts.exclusive/1))
        %{"toggle" => id} -> Alerts.toggle_rule(id)
        %{"remove" => id} -> Alerts.delete_rule(id)
      end
    end

    {:noreply, assign(socket, rules: Alerts.rules(), who: People.audience_rows())}
  end

  def handle_event("who", %{"who" => params}, socket) do
    if owner?(socket), do: WhoPick.save(params)
    {:noreply, assign(socket, who: People.audience_rows())}
  end

  def handle_event("person", %{"person" => %{"id" => id} = given} = sent, socket) do
    socket = assign(socket, where: sent["at"] || "person-" <> id)

    with true <- owner?(socket) do
      params =
        Enum.reduce(~w(pushover_user pagerduty_key), given, fn k, acc ->
          cond do
            acc["clear_" <> k] == "true" -> Map.put(acc, k, "")
            acc[k] in [nil, ""] -> Map.delete(acc, k)
            true -> acc
          end
        end)

      case People.update(id, params) do
        {:ok, _} ->
          socket = assign(socket, people: People.list(), saved: true, error: nil, note: nil)

          if sent["test"],
            do: person_test(socket, id, sent["test"]),
            else: {:noreply, socket}

        {:error, error} ->
          {:noreply, assign(socket, saved: false, error: error, note: nil)}

        :not_found ->
          {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
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
         waiting: "imessage",
         tests:
           Map.put(socket.assigns.tests, "imessage", {:wait, "Waiting for the Mac to answer."})
       )
       |> start_async(:imessage, fn ->
         {"imessage", DokkitWeb.ApiController.try_alert(%{"channel" => "imessage"}, user)}
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

  def handle_async(:imessage, {:ok, {key, answer}}, socket),
    do:
      {:noreply,
       assign(socket,
         waiting: false,
         imessage: Alerts.imessage_status(),
         tests: Map.put(socket.assigns.tests, key, answer(answer))
       )}

  def handle_async(:imessage, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket,
         waiting: false,
         tests:
           Map.put(
             socket.assigns.tests,
             socket.assigns.waiting,
             {:error, "The test did not finish."}
           )
       )}

  defp add_rule(rule) do
    list = Alerts.add_rule(rule)
    to = Enum.reject(rule["to"] || [], &(&1 == ""))
    to = if "everyone" in to, do: ["everyone"], else: to
    if to != [], do: People.set_who("rule", List.last(list)["id"], to)
  end

  defp person_test(socket, id, channel) do
    key = id <> ":" <> channel
    params = %{"channel" => channel, "person" => id}
    user = socket.assigns.current_user.id

    cond do
      channel == "imessage" and socket.assigns.waiting ->
        {:noreply, socket}

      channel == "imessage" ->
        {:noreply,
         socket
         |> assign(
           waiting: key,
           tests: Map.put(socket.assigns.tests, key, {:wait, "Waiting for the Mac to answer."})
         )
         |> start_async(:imessage, fn ->
           {key, DokkitWeb.ApiController.try_alert(params, user)}
         end)}

      true ->
        {:noreply,
         assign(socket,
           tests:
             Map.put(
               socket.assigns.tests,
               key,
               answer(DokkitWeb.ApiController.try_alert(params, user))
             )
         )}
    end
  end

  defp test_result(channel, socket),
    do:
      answer(
        DokkitWeb.ApiController.try_alert(%{"channel" => channel}, socket.assigns.current_user.id)
      )

  defp answer(%{ok: true}), do: {:ok, "Sent. Check that it arrived."}
  defp answer({:error, _, text}), do: {:error, text}

  defp no_mac?(config, key),
    do: "imessage" in Alerts.split(config[key]) and config["imessage_machine"] in [nil, ""]

  defp rule_no_mac?(rules, config),
    do:
      Enum.any?(rules, &(&1["on"] and "imessage" in &1["channels"])) and
        config["imessage_machine"] in [nil, ""]

  @choices ~w(down degraded self_down self_degraded)

  defp alone(params, config) do
    for {k, v} <- params, into: %{} do
      if k in @choices and is_list(v), do: {k, Alerts.exclusive(v, config[k])}, else: {k, v}
    end
  end

  # Keep what was typed, so a page update does not put the saved values back over it.
  defp typed(socket, params, error) do
    {secrets, plain} = params |> alone(socket.assigns.config) |> Map.split(@secrets)

    assign(socket,
      config: Map.merge(socket.assigns.config, plain),
      typed: secrets,
      saved: false,
      note: nil,
      error: error
    )
  end

  defp hm(at), do: Calendar.strftime(at, "%H:%M")

  defp zone_now(config) do
    if Alerts.zone_set?(config) do
      hour = fn k -> String.pad_leading("#{Alerts.night_hour(config, k)}", 2, "0") <> ":00" end

      "It is now #{hm(Alerts.local(DateTime.utc_now(), config))} there; night is #{hour.("night_from")} to #{hour.("night_to")}."
    end
  end

  defp offset(config) do
    case Alerts.night_hour(config, "night_offset") do
      0 -> ""
      n -> " with an offset of #{if n > 0, do: "+"}#{n} hours"
    end
  end

  defp owner?(socket), do: socket.assigns.current_user.role == :owner

  def render(assigns) do
    assigns =
      assign(assigns,
        channels: Alerts.channels(),
        kinds: Alerts.rule_kinds(),
        states: Alerts.rule_states(),
        push: @push,
        self: Alerts.self_routes(assigns.config),
        owner: assigns.current_user.role == :owner,
        zones: Alerts.zones(),
        zone_now: zone_now(assigns.config),
        offset: offset(assigns.config),
        utc_now: hm(DateTime.utc_now()),
        local_now: hm(Alerts.local(DateTime.utc_now(), assigns.config))
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
          <div class="card" id="pagerduty">
            <h2>PagerDuty</h2>
            
            <dl class="kv">
              <dt>Page</dt>
              
              <dd>
                <.secret
                  typed={@typed}
                  name="pagerduty_key"
                  config={@config}
                  label="PagerDuty routing key"
                /> <.send_test channel="page" stays tests={@tests} />
                <span class="hint">
                  Through PagerDuty, for what cannot wait until morning. The key is the integration key of an Events API v2 integration. The page is resolved when the issue closes.
                </span>
              </dd>
            </dl>
            
            <.save
              at="pagerduty"
              where={@where}
              saved={@saved}
              error={@error}
              note={@note}
              owner={@owner}
            />
          </div>
          
          <div class="card" id="push">
            <h2>Push</h2>
            
            <dl class="kv">
              <dt>Push</dt>
              
              <dd>
                <.pick
                  name="push_with"
                  value={@config["push_with"]}
                  options={@push}
                  label="Push goes through"
                /> <.send_test channel="push" stays={@config["push_with"] == "pagerduty"} tests={@tests} />
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
            
            <.save at="push" where={@where} saved={@saved} error={@error} note={@note} owner={@owner} />
          </div>
          
          <div class="card" id="email">
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
            
            <.save
              at="email"
              where={@where}
              saved={@saved}
              error={@error}
              note={@note}
              owner={@owner}
            />
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
              
              <dt>Status</dt>
              
              <dd>
                <span :if={elem(@imessage, 0) == :ready} class="tag ok">Set up</span>
                <span
                  class={["hint", elem(@imessage, 0) == :missing && "bad"]}
                  style="flex-basis: auto"
                  id="imessage-status"
                >{elem(@imessage, 1)}</span>
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
            
            <.save
              at="imessage"
              where={@where}
              saved={@saved}
              error={@error}
              note={@note}
              owner={@owner}
            />
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
            
            <.save at="sms" where={@where} saved={@saved} error={@error} note={@note} owner={@owner} />
          </div>
          
          <div class="card" id="webhook">
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
                  An https address. A JSON request when an issue opens and another when it closes. A Slack or Discord webhook address gets a message in their own format.
                </span>
              </dd>
            </dl>
            
            <.save
              at="webhook"
              where={@where}
              saved={@saved}
              error={@error}
              note={@note}
              owner={@owner}
            />
          </div>
          
          <div class="card" id="who">
            <h2>Who is told</h2>
            
            <dl class="kv">
              <dt>When something stops</dt>
              
              <dd>
                <ChannelPick.pick
                  name="alerts[down]"
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
                <ChannelPick.pick
                  name="alerts[degraded]"
                  value={@config["degraded"]}
                  options={@channels}
                  label="When something is struggling"
                />
                <span :if={no_mac?(@config, "degraded")} class="hint bad">
                  iMessage will not send until a Mac is chosen above.
                </span>
                
                <span class="hint">
                  Tick more than one and each sends its own alert. Nobody stands alone. Page and Push through PagerDuty together make one incident, at the page's severity. An issue alerts once, when it opens. If it recovers and fails again inside 30 minutes, that is the same issue and it stays quiet.
                </span>
              </dd>
            </dl>
            
            <dl class="kv">
              <dt>Dokkit stops taking reports</dt>
              
              <dd>
                <ChannelPick.pick
                  name="alerts[self_down]"
                  value={@config["self_down"]}
                  options={@channels}
                  blank={"Automatic (#{names(@channels, elem(@self, 0))})"}
                  label="When Dokkit stops taking reports or cannot reach its database"
                />
                <span class="hint">
                  Or cannot reach its database. Automatic is the loudest channel that is set up.
                </span>
              </dd>
              
              <dt>Dokkit has lesser trouble</dt>
              
              <dd>
                <ChannelPick.pick
                  name="alerts[self_degraded]"
                  value={@config["self_degraded"]}
                  options={@channels}
                  blank={"Automatic (#{names(@channels, elem(@self, 1))})"}
                  label="When Dokkit has lesser trouble"
                />
                <span class="hint">
                  Its archive folder cannot be written to, or its certificate is close to running out.
                </span>
              </dd>
            </dl>
            
            <.save at="who" where={@where} saved={@saved} error={@error} note={@note} owner={@owner} />
          </div>
          
          <div class="card" id="limits">
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
                  Start hour, end hour and hours from UTC, for example 22, 7 and -5. The hours from UTC are used only while no time zone is chosen. A service set not to wake you at night holds its alerts until the night ends.
                </span>
              </dd>

              <dt>Time zone</dt>

              <dd>
                <input
                  class="inp"
                  style="flex: 1 1 240px"
                  name="alerts[night_zone]"
                  value={@config["night_zone"]}
                  list="zones"
                  placeholder="America/Los_Angeles"
                  autocomplete="off"
                  aria-label="Time zone for the night and the digest"
                />
                <datalist id="zones">
                  <option :for={z <- @zones} value={z}></option>
                </datalist>
                <span :if={@zone_now} class="hint" id="zone-now">{@zone_now}</span>
                <span :if={!@zone_now} class="hint bad" id="zone-warning" role="alert">
                  No time zone is chosen, so the night is read in UTC{@offset}. The server's clock says {@utc_now} UTC, so it thinks it is {@local_now} where the night is kept. Alerts held for a service are held by that clock.
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
                  aria-label="Digest time"
                />
                <span class="hint">
                  One email a day at this time, in the time zone above (UTC while none is chosen): what opened without paging, new errors, and numbers close to a limit. A day with nothing to say sends nothing.
                </span>
              </dd>
            </dl>
            
            <.save
              at="limits"
              where={@where}
              saved={@saved}
              error={@error}
              note={@note}
              owner={@owner}
            />
          </div>
        </fieldset>
      </form>
      
      <div class="body set" style="padding-top: 0">
        <fieldset disabled={!@owner} style="display: contents">
          <div class="card" id="people">
            <h2>People<span class="cnt">{length(@people)}</span></h2>
            
            <dl class="kv">
              <dt>Told by default</dt>
              
              <dd>
                <WhoPick.pick
                  scope="default"
                  people={@people}
                  who={@who}
                  above="Everyone: the destinations above."
                  disabled={!@owner}
                />
                <span class="hint">
                  A rule, a service or a check can name other people. The most specific one wins: a check, then a service, then a rule, then this.
                </span>
              </dd>
            </dl>
          </div>
          
          <form
            :for={p <- @people}
            class="card"
            phx-submit="person"
            id={"person-#{p.id}"}
          >
            <h2>{p.name}<span class="cnt">{p.role}</span></h2>
             <input type="hidden" name="person[id]" value={p.id} />
            <dl class="kv">
              <dt>Email</dt>
              
              <dd>
                <input
                  class="inp"
                  style="flex: 1 1 260px"
                  name="person[email]"
                  value={p.email}
                  placeholder="name@example.com"
                  aria-label={"Email for #{p.name}"}
                /> <.send_test channel="email" as={p.id <> ":email"} tests={@tests} />
              </dd>
              
              <dt>SMS</dt>
              
              <dd>
                <input
                  class="inp"
                  style="flex: 1 1 260px"
                  name="person[phone]"
                  value={p.phone}
                  placeholder="+15555550100"
                  aria-label={"Phone for SMS for #{p.name}"}
                /> <.send_test channel="sms" as={p.id <> ":sms"} tests={@tests} />
              </dd>
              
              <dt>iMessage</dt>
              
              <dd>
                <input
                  class="inp"
                  style="flex: 1 1 260px"
                  name="person[imessage]"
                  value={p.imessage}
                  placeholder="+15555550100 or name@example.com"
                  aria-label={"iMessage address for #{p.name}"}
                /> <.send_test channel="imessage" as={p.id <> ":imessage"} tests={@tests} />
              </dd>
              
              <dt>Push</dt>
              
              <dd>
                <input
                  class="inp"
                  style="flex: 1 1 260px"
                  name="person[ntfy_url]"
                  value={@owner && p.ntfy_url}
                  placeholder="https://ntfy.sh/their-topic"
                  aria-label={"ntfy topic address for #{p.name}"}
                />
                <.secret
                  prefix="person"
                  name="pushover_user"
                  config={%{"pushover_user" => p.pushover_user}}
                  label="Pushover user key"
                /> <.send_test channel="push" stays={@config["push_with"] == "pagerduty"} as={p.id <> ":push"} tests={@tests} />
              </dd>
              
              <dt>Page</dt>
              
              <dd>
                <.secret
                  prefix="person"
                  name="pagerduty_key"
                  config={%{"pagerduty_key" => p.pagerduty_key}}
                  label="PagerDuty routing key"
                /> <.send_test channel="page" stays as={p.id <> ":page"} tests={@tests} />
                <span class="hint">
                  Only when this person has a PagerDuty integration of their own. Push goes the way chosen above.
                </span>
              </dd>
            </dl>
            
            <.save
              at={"person-" <> p.id}
              where={@where}
              saved={@saved}
              error={@error}
              note={@note}
              owner={@owner}
            />
          </form>
        </fieldset>
      </div>
      
      <div class="body set" style="padding-top: 0">
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
              
              <span style="grid-column: 1 / -1">
                <WhoPick.pick
                  scope="rule"
                  id={r["id"]}
                  people={@people}
                  who={@who}
                  above="Told as set above."
                  disabled={!@owner}
                />
              </span>
            </div>
            
            <form phx-submit="rule" id="rule-form">
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
                  <ChannelPick.pick
                    name="rule[channel]"
                    options={@channels}
                    label="Rule channels"
                    blank="Nobody"
                  />
                  
                  <span style="display: inline-flex; flex-wrap: wrap; gap: 4px 14px">
                    <label style="display: inline-flex; align-items: center; gap: 6px">
                      <input type="checkbox" class="chk" name="rule[to][]" value="everyone" />
                      Everyone
                    </label>
                    
                    <label
                      :for={person <- @people}
                      style="display: inline-flex; align-items: center; gap: 6px"
                    >
                      <input type="checkbox" class="chk" name="rule[to][]" value={person.id} /> {person.name}
                    </label>
                  </span>
                   <button class="btn" type="submit">Add the rule</button>
                  <span class="hint">
                    The first rule that fits an issue decides its channel. A service's own routing comes first. Naming no one tells the people chosen by default.
                  </span>
                </dd>
              </dl>
            </form>
          </div>
        </fieldset>
      </div>
    </Layouts.app>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :options, :list, required: true
  attr :label, :string, required: true
  attr :blank, :string, default: nil

  defp pick(assigns) do
    ~H"""
    <span class="dd wide">
      <select class="inp" name={"alerts[#{@name}]"} aria-label={@label}>
        <option :if={@blank} value="" selected={@value in [nil, ""]}>{@blank}</option>
        
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
  attr :prefix, :string, default: "alerts"

  defp secret(assigns) do
    assigns = assign(assigns, set: assigns.config[assigns.name] not in [nil, ""])

    ~H"""
    <input
      class="inp"
      style="flex: 1 1 200px"
      type="password"
      name={"#{@prefix}[#{@name}]"}
      autocomplete="new-password"
      aria-label={@label}
      value={@typed[@name]}
      placeholder={if @set, do: "#{@label}: kept, type to replace", else: @label}
    />
    <label :if={@set} class="hint">
      <input type="checkbox" name={"#{@prefix}[clear_#{@name}]"} value="true" /> Clear
    </label>
    """
  end

  defp describe(rule, kinds, states, channels) do
    on = if rule["machine"] == "", do: "", else: " on #{rule["machine"]}"

    "When #{String.downcase(name(kinds, rule["kind"]))} #{name(states, rule["state"])}#{on}: " <>
      Enum.map_join(rule["channels"], " and ", &name(channels, &1))
  end

  defp name(options, value),
    do: Enum.find_value(options, "", fn {text, v} -> v == value && text end)

  defp names(options, value),
    do: value |> Alerts.split() |> Enum.map_join(" and ", &name(options, &1))

  attr :at, :string, required: true
  attr :where, :string, default: nil
  attr :saved, :boolean, default: false
  attr :error, :string, default: nil
  attr :note, :string, default: nil
  attr :owner, :boolean, required: true

  # Each block saves from where it is, and says so there.
  defp save(assigns) do
    ~H"""
    <div class="foot">
      <span :if={!@owner}>Only the owner can change these.</span>
      <span :if={@saved and @where == @at} role="status">Saved. {@note}</span>
      <span :if={@error && @where == @at} role="alert">{@error}</span>
      <span class="end">
        <button class="btn primary" type="submit" name="at" value={@at}>Save</button>
      </span>
    </div>
    """
  end

  attr :channel, :string, required: true
  attr :tests, :map, required: true
  attr :as, :string, default: nil
  attr :stays, :boolean, default: false

  defp send_test(assigns) do
    assigns = assign(assigns, result: assigns.tests[assigns.as || assigns.channel])

    ~H"""
    <button class="btn" type="submit" name="test" value={@channel} phx-disable-with="Sending">
      Send a test
    </button>

    <span :if={@stays} class="hint">This test stays open for two minutes, then resolves itself.</span>

    <span :if={@result} class={["hint", elem(@result, 0) == :error && "bad"]} role="status">{elem(
      @result,
      1
    )}</span>
    """
  end
end
