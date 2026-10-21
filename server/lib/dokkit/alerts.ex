defmodule Dokkit.Alerts do
  @moduledoc """
  Tells people about issues. An issue alerts once, when it opens, and what it raised is
  resolved when it closes. Rows are written with the issue and sent afterwards, so a
  restart or a failed send loses nothing.
  """
  use GenServer
  import Ecto.Query
  require Logger
  alias Dokkit.{Alert, Issue, Machine, People, Repo, Service, Setting, WorkRun}

  @defaults %{
    "down" => "page",
    "degraded" => "push",
    "push_with" => "ntfy",
    "disk_limit" => "90",
    "memory_limit" => "95",
    "night_from" => "22",
    "night_to" => "7",
    "night_offset" => "0"
  }
  @secrets ~w(pagerduty_key ntfy_token pushover_token pushover_user smtp_password twilio_token)
  @plain ~w(disk_limit memory_limit ntfy_url webhook_url smtp_host smtp_port smtp_user mail_from email_to digest_at heartbeat_url imessage_machine imessage_to twilio_sid twilio_from sms_to self_down self_degraded night_zone)
  @choices ~w(down degraded self_down self_degraded)
  @max_attempts 5
  @imessage_wait 300
  @smtp_ports [25, 465, 587, 2525]
  @kept_blank ~w(disk_limit memory_limit)
  @channels [
    {"Page", "page"},
    {"Push", "push"},
    {"Email", "email"},
    {"iMessage", "imessage"},
    {"SMS", "sms"},
    {"Daily digest", "digest"},
    {"Webhook", "webhook"},
    {"Nobody", "none"}
  ]

  def channels, do: @channels

  @doc "The channels in a stored or given choice, a list or text with commas. Unknown words are dropped."
  def split(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&List.keymember?(@channels, &1, 1))
    |> Enum.uniq()
  end

  def split(value) when is_binary(value), do: split(String.split(value, ","))
  def split(_), do: []

  @doc "A choice of channels as it is stored: names with commas between, or empty."
  def choice(value), do: value |> split() |> Enum.join(",")

  @doc "A ticked choice with `none` made to stand alone: it wins when it was ticked last, and gives way to a channel ticked after it."
  def exclusive(new, old \\ []) do
    new = split(new)

    cond do
      "none" not in new or length(new) == 1 -> new
      "none" in split(old) or old == [] -> List.delete(new, "none")
      true -> ["none"]
    end
  end

  @doc "An error for a choice of channels that names an unknown one or mixes none with others, or nil."
  def channel_error(value) do
    given = if is_binary(value), do: String.split(value, ","), else: value

    cond do
      not is_list(given) or not Enum.all?(given, &is_binary/1) ->
        "A channel is text, or a list of text."

      true ->
        given = given |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

        cond do
          Enum.any?(given, &(not List.keymember?(@channels, &1, 1))) ->
            "A channel is one of #{Enum.map_join(@channels, ", ", &elem(&1, 1))}."

          "none" in given and length(given) > 1 ->
            "none cannot be combined with other channels."

          true ->
            nil
        end
    end
  end

  def sends?(channel), do: channel != "none" and List.keymember?(@channels, channel, 1)

  @sent %{
    "page" => "Paged",
    "push" => "Pushed",
    "email" => "Emailed",
    "imessage" => "Sent an iMessage",
    "sms" => "Sent an SMS",
    "text" => "Texted",
    "webhook" => "Webhook called"
  }

  @doc "What is said of an alert that went out by this channel, or nil."
  def sent_word(channel), do: @sent[channel]

  def secrets, do: @secrets

  @doc "The enrolled Macs, which can send iMessages."
  def macs,
    do:
      Repo.all(
        from m in Machine, where: m.kind == :enrolled and m.os == "darwin", order_by: m.name
      )

  def smtp_ports, do: @smtp_ports

  def config do
    Map.merge(@defaults, unblank(Setting.get("alerts")))
  end

  # A blank value falls back to its default; a blank limit switches that limit off.
  defp unblank(map),
    do: Map.reject(map, fn {k, v} -> v == "" and k not in @secrets and k not in @kept_blank end)

  # A secret is sent to one host. If that host changes, the secret goes with it only when it is
  # sent again in the same save.
  @bound [{"ntfy_url", "ntfy_token", :url}, {"smtp_host", "smtp_password", :host}]

  @doc "The secrets a save of `params` clears because the host they are sent to changes and they are not sent again."
  def cleared(params, old \\ config()) do
    for {key, secret, kind} <- @bound,
        is_binary(params[key]),
        host(params[key], kind) != host(old[key], kind),
        old[secret] not in [nil, ""],
        String.trim(params[secret] || "") == "",
        do: secret
  end

  defp host(value, :host), do: String.downcase(String.trim(value || ""))

  defp host(value, :url),
    do: (URI.parse(String.trim(value || "")).host || "") |> String.downcase()

  @doc "The words that say a save cleared a secret, or nil."
  def cleared_note(names) when names != [],
    do:
      "#{Enum.join(names, " and ")} #{if length(names) == 1, do: "was", else: "were"} cleared because the address it is sent to changed. Send it again in the same save to keep it."

  def cleared_note(_), do: nil

  @doc "Saves what was filled in. A secret that is not given keeps its value; an empty one clears it."
  def save(params) do
    old = config()
    gone = cleared(params, old)

    new =
      for({k, v} <- Map.take(params, Map.keys(@defaults) ++ @secrets ++ @plain), into: old) do
        {k, if(k in @choices, do: choice(v), else: String.trim(v))}
      end
      |> Map.merge(Map.new(gone, &{&1, ""}))
      |> unblank()

    Setting.put("alerts", new)

    new
  end

  def setting_keys, do: Map.keys(@defaults) ++ @secrets ++ @plain

  @hidden @secrets ++ ~w(ntfy_url webhook_url heartbeat_url smtp_user twilio_sid)

  @doc "The settings as the API shows them: addresses, user names and secrets are only set or not set."
  def view do
    c = config()
    marks = Map.new(@hidden, &{&1, if(c[&1] in [nil, ""], do: "not set", else: "set")})
    {_, notice} = imessage_status(c)
    lists = Map.new(@choices, &{&1 <> "_channels", split(c[&1])})

    c
    |> Map.drop(@hidden)
    |> Map.merge(marks)
    |> Map.merge(lists)
    |> Map.put("imessage_status", notice)
  end

  @doc """
  Checks the settings, then saves them. `{:ok, config, note}` or `{:error, text}`. The note says
  which secrets the save cleared because their address changed, or is nil.
  """
  def update(params) do
    params =
      for {k, v} <- Map.take(params, setting_keys()), into: %{} do
        if k in @choices and is_list(v) and Enum.all?(v, &is_binary/1),
          do: {k, Enum.join(v, ",")},
          else: {k, v}
      end

    cond do
      Enum.any?(params, fn {_, v} -> not is_binary(v) end) ->
        {:error, "Every setting is text."}

      error =
          bad_choice(params) || night_error(params) || zone_error(params) ||
            bad_recipients(params) || bad_address(params) ->
        {:error, error}

      true ->
        note = cleared_note(cleared(params))
        config = save(params)
        Dokkit.SharedBeat.follow(config)
        {:ok, config, note}
    end
  end

  defp bad_choice(params) do
    Enum.find_value(@choices, fn k ->
      if why = channel_error(params[k] || ""), do: "#{k}: #{why}"
    end) ||
      if String.trim(params["push_with"] || "") not in ["", "ntfy", "pushover", "pagerduty"],
        do: "push_with is one of ntfy, pushover, pagerduty."
  end

  @phone ~r/^\+?[0-9][0-9 ()\-.]{5,19}$/
  @email ~r/^[^@\s,]+@[^@\s,]+\.[^@\s,]+$/

  @doc "The recipients written in a setting, commas between them."
  def recipients(value),
    do: (value || "") |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp bad_recipients(params) do
    bad_mac(params) ||
      recipient_error(params, [
        {"imessage_to", [@phone, @email]},
        {"sms_to", [@phone]},
        {"twilio_from", [@phone]}
      ]) || bad_sid(params)
  end

  defp recipient_error(params, fields) do
    Enum.find_value(fields, fn {k, ok} ->
      Enum.find_value(recipients(params[k]), fn r ->
        unless Enum.any?(ok, &Regex.match?(&1, r)),
          do:
            "#{k}: #{r} is not a #{if length(ok) == 2, do: "phone number or an email address", else: "phone number"}."
      end)
    end)
  end

  @doc "An error for a person's destinations that are not what they should be, or nil."
  def contact_error(params) do
    recipient_error(params, [
      {"email", [@email]},
      {"phone", [@phone]},
      {"imessage", [@phone, @email]}
    ]) ||
      with url when url not in [nil, ""] <- String.trim(params["ntfy_url"] || ""),
           {:error, why} <- check_url(url) do
        "ntfy_url: #{why}"
      else
        _ -> nil
      end
  end

  defp bad_sid(params) do
    unless String.trim(params["twilio_sid"] || "") =~ ~r/^[A-Za-z0-9]*$/,
      do: "twilio_sid is letters and numbers only."
  end

  defp bad_mac(params) do
    id = String.trim(params["imessage_machine"] || "")

    with true <- id != "" do
      mac =
        case Ecto.UUID.cast(id) do
          {:ok, id} -> Repo.get(Machine, id)
          _ -> nil
        end

      unless match?(%Machine{kind: :enrolled, os: "darwin"}, mac),
        do: "iMessage goes out through a Mac. #{(mac && mac.name) || "That machine"} is not one."
    else
      _ -> nil
    end
  end

  defp bad_address(params) do
    Enum.find_value(~w(ntfy_url webhook_url heartbeat_url), fn k ->
      url = String.trim(params[k] || "")

      with true <- url != "", {:error, why} <- check_url(url) do
        "#{String.replace(k, "_url", "")}: #{why}"
      else
        _ -> nil
      end
    end) || bad_mail_server(params)
  end

  defp bad_mail_server(params) do
    host = String.trim(params["smtp_host"] || "")
    port = String.trim(params["smtp_port"] || "")

    if port != "" and port not in Enum.map(@smtp_ports, &to_string/1) do
      "smtp_port is one of #{Enum.join(@smtp_ports, ", ")}."
    else
      with true <- host != "",
           {:error, why} <- resolve(host),
           do: "smtp_host: #{why}",
           else: (_ -> nil)
    end
  end

  @doc """
  The time on the clock where the night is kept: in the time zone set on the Alerts page, else
  `now` moved by the old whole-hour offset from UTC.
  """
  def local(now, config \\ config()) do
    case zone_now(now, config) do
      %DateTime{time_zone: "Etc/UTC"} ->
        DateTime.add(now, night_hour(config, "night_offset", -12..14) * 3600)

      local ->
        local
    end
  end

  @doc "`now` in the time zone set on the Alerts page, or in UTC when none is set."
  def zone_now(now, config \\ config()) do
    with zone when zone not in [nil, ""] <- config["night_zone"],
         {:ok, local} <- DateTime.shift_zone(now, zone) do
      local
    else
      _ -> now
    end
  end

  @doc "Whether the Alerts page has a time zone set that the database knows."
  def zone_set?(config \\ config()),
    do: match?({:ok, _}, DateTime.shift_zone(DateTime.utc_now(), config["night_zone"] || ""))

  @doc "Whether `now` falls in the night set on the Alerts page."
  def night?(now, config \\ config()) do
    from = night_hour(config, "night_from", 0..23)
    to = night_hour(config, "night_to", 0..23)
    hour = local(now, config).hour
    if from <= to, do: hour >= from and hour < to, else: hour >= from or hour < to
  end

  defp night_hour(config, key, range) do
    whole_hour(config[key], range) || String.to_integer(@defaults[key])
  end

  @doc "A whole-hour night setting: `night_from`, `night_to` or `night_offset`."
  def night_hour(config, key),
    do: night_hour(config, key, if(key == "night_offset", do: -12..14, else: 0..23))

  defp whole_hour(value, range) do
    case Integer.parse(value || "") do
      {n, ""} -> if n in range, do: n
      _ -> nil
    end
  end

  @doc "When the night ends, in the night's own clock, such as \"07:00 PDT\" or \"07:00 UTC+2\"."
  def night_ends(config \\ config(), now \\ DateTime.utc_now()) do
    hour = night_hour(config, "night_to", 0..23) |> to_string() |> String.pad_leading(2, "0")
    offset = night_hour(config, "night_offset", -12..14)

    case zone_now(now, config) do
      %DateTime{time_zone: "Etc/UTC"} ->
        "#{hour}:00 UTC#{if offset > 0, do: "+#{offset}", else: if(offset < 0, do: offset)}"

      %DateTime{zone_abbr: abbr} ->
        "#{hour}:00 #{abbr}"
    end
  end

  @doc "An error for a time zone the database does not know, or nil."
  def zone_error(params) do
    zone = String.trim(params["night_zone"] || "")

    if zone != "" and not match?({:ok, _}, DateTime.shift_zone(DateTime.utc_now(), zone)),
      do: "night_zone is a time zone name such as America/Los_Angeles."
  end

  @zones ~w(UTC Pacific/Honolulu America/Anchorage America/Los_Angeles America/Phoenix America/Denver America/Chicago America/New_York America/Halifax America/St_Johns America/Sao_Paulo America/Mexico_City America/Toronto America/Vancouver Atlantic/Reykjavik Europe/London Europe/Dublin Europe/Lisbon Europe/Paris Europe/Berlin Europe/Madrid Europe/Rome Europe/Amsterdam Europe/Stockholm Europe/Athens Europe/Helsinki Europe/Istanbul Europe/Moscow Africa/Cairo Africa/Lagos Africa/Johannesburg Africa/Nairobi Asia/Dubai Asia/Karachi Asia/Kolkata Asia/Dhaka Asia/Bangkok Asia/Singapore Asia/Hong_Kong Asia/Shanghai Asia/Tokyo Asia/Seoul Australia/Perth Australia/Adelaide Australia/Sydney Australia/Brisbane Pacific/Auckland)

  @doc "Common time zone names to pick from."
  def zones, do: @zones

  @doc "An error for a night that is not whole hours, or nil."
  def night_error(params) do
    ranges = [{"night_from", 0..23}, {"night_to", 0..23}, {"night_offset", -12..14}]

    unless Enum.all?(ranges, fn {k, r} ->
             v = String.trim(params[k] || "")
             v == "" or whole_hour(v, r) != nil
           end),
           do: "The night is whole hours: 0 to 23, and the hours from UTC from -12 to 14."
  end

  @kinds [{"Anything", ""}, {"A job", "job"}, {"A check", "check"}, {"A machine", "machine"}]
  @states [{"stops or struggles", ""}, {"stops", "down"}, {"struggles", "degraded"}]
  def rule_kinds, do: @kinds
  def rule_states, do: @states

  @doc "Rules, first match first. A service's own routing comes before them, the two defaults after."
  def rules do
    for r <- Setting.get("rules")["list"] || [],
        do: Map.put(r, "channels", split(r["channel"]))
  end

  def add_rule(params),
    do: save_rules(rules() ++ [Map.merge(rule(params), %{"id" => Ecto.UUID.generate()})])

  @doc "Changes what a rule says; a field that is not given stays as it was. Its place in the order stays."
  def update_rule(id, params) do
    save_rules(
      for r <- rules() do
        if r["id"] == id do
          given =
            Map.take(
              rule(params),
              Enum.map(Map.keys(params), &if(&1 == "channels", do: "channel", else: &1))
            )

          on = if is_boolean(params["on"]), do: params["on"], else: r["on"]
          r |> Map.merge(given) |> Map.put("on", on)
        else
          r
        end
      end
    )
  end

  defp rule(params) do
    %{
      "kind" => pick(@kinds, params["kind"]),
      "state" => pick(@states, params["state"]),
      "machine" => if(is_binary(params["machine"]), do: String.trim(params["machine"]), else: ""),
      "channel" =>
        if((c = choice(params["channels"] || params["channel"])) == "", do: "none", else: c),
      "on" => true
    }
  end

  @doc "An error for a rule whose fields are not text, a known word, or true or false; else nil."
  def rule_error(params) do
    words = %{"kind" => @kinds, "state" => @states}

    Enum.find_value(~w(kind state channel channels machine on), fn k ->
      v = params[k]

      cond do
        not Map.has_key?(params, k) ->
          nil

        k in ["channel", "channels"] ->
          channel_error(v)

        k == "on" ->
          if not is_boolean(v), do: "on is true or false."

        k == "machine" ->
          if not is_binary(v), do: "machine is text."

        is_binary(v) and (v == "" or List.keymember?(words[k], v, 1)) ->
          nil

        true ->
          "#{k} is one of #{words[k] |> Enum.map(&elem(&1, 1)) |> Enum.reject(&(&1 == "")) |> Enum.join(", ")}, or empty."
      end
    end)
  end

  def toggle_rule(id),
    do:
      save_rules(
        for r <- rules(), do: if(r["id"] == id, do: Map.update!(r, "on", &(!&1)), else: r)
      )

  def delete_rule(id) do
    People.forget("rule", id)
    save_rules(Enum.reject(rules(), &(&1["id"] == id)))
  end

  @often 6

  @doc """
  Changes worth offering: an issue that has opened six times or more in a month and is
  snoozed, while its service still sends somewhere louder than the digest. Nothing here
  changes a rule; a person accepts or dismisses.
  """
  def suggestions do
    dismissed =
      Setting.get("suggestions")["dismissed"] || []

    since = DateTime.add(DateTime.utc_now(), -30 * 86_400)

    Repo.all(
      from i in Issue,
        join: s in assoc(i, :service),
        where: i.count >= @often and not is_nil(i.snoozed_until) and i.since > ^since,
        where: s.id not in ^dismissed,
        order_by: [desc: i.count],
        preload: [service: s]
    )
    |> Enum.reject(&(split(route(&1.service, &1.state)) == ["digest"]))
    |> Enum.uniq_by(& &1.service_id)
  end

  defp route(service, :down), do: service.route_down
  defp route(service, _), do: service.route_degraded

  @doc "Sends that service's issues of that kind to the daily digest from now on."
  def accept_suggestion(issue_id) do
    with %Issue{} = i <- Enum.find(suggestions(), &(&1.id == issue_id)) do
      field = if i.state == :down, do: :route_down, else: :route_degraded
      Repo.update!(Ecto.Changeset.change(i.service, [{field, "digest"}]))
    end
  end

  def dismiss_suggestion(issue_id) do
    with %Issue{} = i <- Enum.find(suggestions(), &(&1.id == issue_id)) do
      old = Setting.get("suggestions")["dismissed"] || []

      Setting.put("suggestions", %{"dismissed" => [i.service_id | old]})
    end
  end

  @doc "The channels the row for Dokkit itself uses when it stops taking reports (down) and for lesser trouble (degraded)."
  def self_routes(config \\ config()) do
    {blank(choice(config["self_down"]), highest(config)),
     blank(choice(config["self_degraded"]), "push")}
  end

  defp blank("", fallback), do: fallback
  defp blank(value, _), do: value

  @doc "The loudest channel that is set up: a page, then SMS, iMessage, push, email."
  def highest(config) do
    set? = &(config[&1] not in [nil, ""])

    cond do
      set?.("pagerduty_key") -> "page"
      set?.("twilio_sid") and set?.("twilio_token") and set?.("sms_to") -> "sms"
      set?.("imessage_machine") and set?.("imessage_to") -> "imessage"
      set?.("ntfy_url") or (set?.("pushover_token") and set?.("pushover_user")) -> "push"
      set?.("email_to") -> "email"
      true -> "push"
    end
  end

  defp pick(options, value), do: Enum.find_value(options, "", fn {_, v} -> v == value && v end)

  defp first_set(choices),
    do: Enum.find_value(choices, [], &(split(&1) != [] && split(&1)))

  defp one_incident(channels, config) do
    if "page" in channels and config["push_with"] == "pagerduty",
      do: List.delete(channels, "push"),
      else: channels
  end

  defp save_rules(list) do
    Setting.put("rules", %{"list" => list})

    list
  end

  defp ruled(%Issue{} = issue, machine) do
    kind = if issue.kind in ~w(job machine), do: issue.kind, else: "check"

    Enum.find(rules(), fn r ->
      r["on"] and r["kind"] in ["", kind] and r["state"] in ["", to_string(issue.state)] and
        r["machine"] in ["", machine]
    end)
  end

  defp machine_name(id),
    do: Repo.one(from m in Dokkit.Machine, where: m.id == ^id, select: m.name)

  # A machine that is down alerts once for itself. What runs on it stays quiet until it is back.
  def plan(issue, service, now \\ DateTime.utc_now())

  def plan(%Issue{} = issue, %Service{environment: "production"} = service, now) do
    {channels, rule} = routed(issue, service, config())

    unless Dokkit.Issues.machine_down?(issue.machine_id) do
      insert(issue, channels, &holds?(service, &1, now), rule)
    end
  end

  def plan(%Issue{kind: "machine"} = issue, nil, now) do
    machine = Repo.get(Machine, issue.machine_id)
    {channels, rule} = routed(issue, nil, config())
    wakes = machine == nil or machine.silent_wake

    insert(issue, channels, &(not wakes and held?(&1, now)), rule)
  end

  def plan(_, _, _), do: nil

  # Where an issue's alerts go now, and the rule that chose it.
  defp routed(%Issue{kind: "machine"} = issue, nil, config) do
    machine = Repo.get(Machine, issue.machine_id)
    rule = rule_for(issue, machine && machine.name)

    channels =
      first_set([machine && machine.silent_route, rule && rule["channel"], config["down"]])

    {finish(channels, issue, config), rule}
  end

  defp routed(issue, service, config) do
    rule = rule_for(issue, machine_name(issue.machine_id))

    channels =
      first_set([
        service && Map.get(service, :"route_#{issue.state}"),
        rule && rule["channel"],
        config[to_string(issue.state)]
      ])

    {finish(channels, issue, config), rule}
  end

  # A soon issue never pages: a page for it goes as a push.
  defp finish(channels, issue, config) do
    channels =
      if issue.soon,
        do: channels |> Enum.map(&if(&1 == "page", do: "push", else: &1)) |> Enum.uniq(),
        else: channels

    one_incident(channels, config)
  end

  # The channels an issue goes to as things are set now; only production services alert.
  defp current(%Issue{service: %Service{environment: env}}, _) when env != "production", do: []

  defp current(issue, config) do
    service = if match?(%Service{}, issue.service), do: issue.service
    issue |> routed(service, config) |> elem(0)
  end

  # A soon issue takes no rule, except one that sends to nobody: a machine set to stay quiet stays quiet.
  defp rule_for(%Issue{soon: true} = issue, machine) do
    rule = ruled(issue, machine)
    if rule && split(rule["channel"]) == ["none"], do: rule
  end

  defp rule_for(issue, machine), do: ruled(issue, machine)

  # A held alert waits in the database for the sweep after the night ends.
  defp holds?(%Service{night: false}, channel, now), do: held?(channel, now)
  defp holds?(_, _, _), do: false

  defp held?(channel, now), do: channel != "digest" and night?(now)

  @doc "Alerts held for a machine that stopped reporting go out now: it was set to wake someone at night."
  def wake_machine(%Machine{id: id}) do
    Repo.update_all(
      from(a in Alert,
        join: i in assoc(a, :issue),
        where: a.status == :held and i.machine_id == ^id and i.kind == "machine"
      ),
      set: [status: :pending]
    )
  end

  # An issue that opens again inside the 30 minutes is told to whoever is named now.
  defp retarget(issue) do
    rule = rule_for(issue, machine_name(issue.machine_id))

    who =
      People.audience(check: issue.check_id, service: issue.service_id, rule: rule && rule["id"])

    ids = if who == :everyone, do: [], else: who

    for a <- Repo.all(from a in Alert, where: a.issue_id == ^issue.id and a.status == :pending) do
      Repo.delete_all(
        from t in Dokkit.AlertTarget, where: t.alert_id == ^a.id and t.person_id not in ^ids
      )

      People.target(a.id, who)
    end
  end

  defp insert(issue, channels, held?, rule) do
    for channel <- channels, sends?(channel) do
      status = if held?.(channel), do: :held, else: :pending
      alert = Repo.insert!(%Alert{issue_id: issue.id, channel: channel, status: status})

      People.target(
        alert.id,
        People.audience(
          check: issue.check_id,
          service: issue.service_id,
          rule: rule && rule["id"]
        )
      )

      alert
    end
  end

  @doc "Held alerts whose night is over are sent if their issue is still open and not snoozed or seen, else dropped. Returns how many go out."
  def release(now \\ DateTime.utc_now()) do
    if night?(now) do
      0
    else
      live =
        from i in Issue,
          where:
            is_nil(i.closed_at) and is_nil(i.acknowledged_at) and
              (is_nil(i.snoozed_until) or i.snoozed_until <= ^now),
          select: i.id

      {n, _} =
        Repo.update_all(
          from(a in Alert, where: a.status == :held and a.issue_id in subquery(live)),
          set: [status: :pending]
        )

      Repo.update_all(
        from(a in Alert, where: a.status == :held and a.issue_id not in subquery(live)),
        set: [status: :skipped]
      )

      n
    end
  end

  @doc "Alerts held for a service go out now: it was set to wake someone at night."
  def wake(%Service{id: id}, now \\ DateTime.utc_now()) do
    Repo.update_all(
      from(a in Alert,
        join: i in assoc(a, :issue),
        where:
          a.status == :held and i.service_id == ^id and is_nil(i.closed_at) and
            is_nil(i.acknowledged_at) and (is_nil(i.snoozed_until) or i.snoozed_until <= ^now)
      ),
      set: [status: :pending]
    )
  end

  @doc """
  An issue that is open again always has a live alert. One that never went out is sent after all.
  One whose page was resolved is paged again, because the resolve closed the incident. One whose
  resolve was never sent, or that has nothing to resolve, stays as it was: nobody is told twice.
  Only channels the issue is routed to now come back, so one that now goes to nobody is not
  told again.
  """
  def reopened(%Issue{id: id} = issue, now \\ DateTime.utc_now()) do
    issue = Repo.preload(issue, :service)
    config = config()
    held = holds?(issue.service, "page", now)
    wanted = current(issue, config)
    live = is_nil(issue.acknowledged_at) and not snoozed?(issue, now)

    if live,
      do:
        Repo.update_all(
          from(a in Alert,
            where: a.issue_id == ^id and a.status == :skipped and a.channel in ^wanted
          ),
          set: [status: :pending, attempts: 0, error: nil]
        )

    Repo.update_all(
      from(a in Alert, where: a.issue_id == ^id and a.status == :closing and a.attempts == 0),
      set: [status: :sent]
    )

    resolved = from(a in Alert, where: a.issue_id == ^id and a.status in [:closing, :closed])
    resolving = if config["push_with"] == "pagerduty", do: ["page", "push"], else: ["page"]
    again = Enum.filter(resolving, &(&1 in wanted))

    if live,
      do:
        Repo.update_all(from(a in resolved, where: a.channel in ^again),
          set: [status: :pending, attempts: 0, error: nil]
        )

    Repo.update_all(from(a in resolved, where: a.channel not in ^resolving), set: [status: :sent])

    Repo.update_all(
      from(t in Dokkit.AlertTarget,
        where:
          t.alert_id in subquery(
            from a in Alert,
              where: a.issue_id == ^id and a.status == :pending and a.channel in ^resolving,
              select: a.id
          )
      ),
      set: [opened: false, closed: false]
    )

    retarget(issue)

    # A channel added to the route since the issue first opened is told now.
    if live and not Dokkit.Issues.machine_down?(issue.machine_id) do
      have = Repo.all(from a in Alert, where: a.issue_id == ^id, select: a.channel)
      {_, rule} = routed(issue, issue.service, config)
      insert(issue, wanted -- have, &holds?(issue.service, &1, now), rule)
    end

    if held,
      do:
        Repo.update_all(
          from(a in Alert,
            where: a.issue_id == ^id and a.status == :pending and a.channel != "digest"
          ),
          set: [status: :held]
        )
  end

  defp snoozed?(%Issue{snoozed_until: nil}, _), do: false
  defp snoozed?(%Issue{snoozed_until: at}, now), do: DateTime.compare(at, now) == :gt

  def closing(%Issue{id: id}) do
    Repo.update_all(
      from(a in Alert,
        where:
          a.issue_id == ^id and a.status == :failed and
            a.id in subquery(
              from t in Dokkit.AlertTarget, where: t.opened and not t.closed, select: t.alert_id
            )
      ),
      set: [status: :closing, attempts: 0]
    )

    Repo.update_all(
      from(a in Alert,
        where: a.issue_id == ^id and a.status in [:pending, :sending, :failed, :held]
      ),
      set: [status: :skipped]
    )

    Repo.update_all(from(a in Alert, where: a.issue_id == ^id and a.status == :sent),
      set: [status: :closing, attempts: 0]
    )
  end

  # Sending happens in one process, so two sweeps never send the same alert twice.
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def init(_), do: {:ok, nil}
  def flush, do: GenServer.cast(__MODULE__, :flush)

  def handle_cast(:flush, state) do
    if deliver_pending() > 0, do: Dokkit.Issues.changed(false)
    {:noreply, state}
  end

  # An alert not yet tried whose channel the issue no longer routes to is dropped, not sent.
  defp rerouted?(%Alert{status: :pending, attempts: 0} = alert, config) do
    gone = alert.channel not in current(alert.issue, config)
    if gone, do: Repo.update!(Ecto.Changeset.change(alert, status: :skipped))
    gone
  end

  defp rerouted?(_, _), do: false

  def deliver_pending do
    config = config()
    settle()

    Repo.all(
      from a in Alert,
        where:
          a.status == :pending or (a.status == :closing and a.attempts == 0) or
            (a.status in [:failed, :closing] and a.attempts < @max_attempts and
               a.updated_at < ago(1, "minute")),
        # A digest alert waits for the day's one mail.
        where: a.channel != "digest",
        preload: [issue: [:machine, :check, :service]]
    )
    |> Enum.reject(&rerouted?(&1, config))
    |> Enum.map(fn alert ->
      action = if alert.status == :closing, do: :close, else: :open

      about = about(alert.issue)
      sent = deliver(alert, action, about, config, People.targets(alert.id))

      change =
        case sent do
          :waiting ->
            [status: :sending, error: nil]

          :ok ->
            [status: if(action == :close, do: :closed, else: :sent), error: nil]

          {:error, text} when action == :close and alert.attempts + 1 >= @max_attempts ->
            [status: :closed, error: text]

          {:error, text} ->
            [status: if(action == :close, do: :closing, else: :failed), error: text]
        end

      if change[:error],
        do: Logger.warning("Alert for #{Issue.short_id(alert.issue)} not sent: #{change[:error]}")

      Repo.update!(Ecto.Changeset.change(alert, [attempts: alert.attempts + 1] ++ change))
    end)
    |> length()
  end

  defp deliver(alert, :open, about, config, [_ | _] = targets) when alert.channel == "imessage" do
    to = targets |> Enum.flat_map(&recipients(&1.person.imessage)) |> Enum.uniq()

    if to == [],
      do: {:error, "None of the people told has an iMessage address."},
      else: imessage(alert, about, Map.put(config, "imessage_to", Enum.join(to, ", ")))
  end

  defp deliver(alert, action, about, config, [_ | _] = targets)
       when alert.channel not in ["imessage", "webhook"] do
    mine =
      Enum.filter(targets, fn t ->
        if action == :open, do: not t.opened, else: t.opened and not t.closed
      end)

    results =
      for t <- mine do
        field = if action == :open, do: :opened, else: :closed
        own = People.overlay(config, t.person, alert.channel)
        for_them = Map.update!(about, :id, &"#{&1}-#{t.person.id}")

        case send_to(provider(alert.channel, own), action, for_them, own) do
          :ok ->
            People.mark(alert.id, t.person.id, field)
            :ok

          {:error, text} ->
            {:error, "#{t.person.name}: #{text}"}
        end
      end

    Enum.find(results, :ok, &(&1 != :ok))
  end

  defp deliver(alert, action, about, config, _) do
    if alert.channel == "imessage" and action == :open,
      do: imessage(alert, about, config),
      else: send_to(provider(alert.channel, config), action, about, config)
  end

  defp not_picked_up(name),
    do: "The Mac that sends iMessages, #{name}, did not pick it up."

  defp imessage_mac(%{"imessage_machine" => id}) when id not in [nil, ""] do
    case Repo.get(Machine, id) do
      %Machine{kind: :enrolled, os: "darwin"} = mac -> {:ok, mac}
      _ -> {:error, "The Mac chosen for iMessage is not enrolled any more."}
    end
  end

  defp imessage_mac(_), do: {:error, "iMessage has no Mac chosen yet."}

  defp imessage_to(config) do
    case recipients(config["imessage_to"]) do
      [] -> {:error, "iMessage has no recipients yet."}
      to -> {:ok, to}
    end
  end

  # One run for an alert at a time: a run still waiting for its Mac is waited on, not repeated.
  defp imessage(alert, about, config) do
    with {:ok, mac} <- imessage_mac(config), {:ok, to} <- imessage_to(config) do
      last =
        Repo.one(
          from r in WorkRun,
            where: r.alert_id == ^alert.id,
            order_by: [desc: r.inserted_at],
            limit: 1
        )

      case last do
        %WorkRun{state: state} when state in [:queued, :running] ->
          if stale?(last, DateTime.utc_now()),
            do: {:error, not_picked_up(mac.name)},
            else: :waiting

        _ ->
          Dokkit.Work.imessage(mac.id, to, summary(about), alert.id)
          :waiting
      end
    end
  end

  defp stale?(%WorkRun{inserted_at: at}, now), do: DateTime.diff(now, at) >= @imessage_wait

  @doc """
  Fails the iMessage alerts whose Mac has not answered in five minutes. Their run stays, so a
  late answer still counts and a retry does not send a second message. Returns how many failed.
  """
  def settle(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@imessage_wait)

    late =
      Repo.all(
        from a in Alert,
          join: r in WorkRun,
          on: r.alert_id == a.id and r.state in [:queued, :running],
          join: m in assoc(r, :machine),
          where: a.status == :sending and r.inserted_at <= ^cutoff,
          select: {a.id, m.name}
      )

    n =
      for {id, name} <- late, reduce: 0 do
        n ->
          {k, _} =
            Repo.update_all(from(a in Alert, where: a.id == ^id and a.status == :sending),
              set: [status: :failed, error: not_picked_up(name), updated_at: now]
            )

          n + k
      end

    if n > 0, do: Dokkit.Issues.changed(false)
    n
  end

  @doc "A finished iMessage run settles its alert, however late it answers."
  def answered(run_id) do
    with %WorkRun{alert_id: id} = run when is_binary(id) <- Repo.get(WorkRun, run_id) do
      set =
        if run.state == :ok,
          do: [status: :sent, error: nil],
          else: [status: :failed, error: reason(run)]

      Repo.update_all(
        from(a in Alert, where: a.id == ^id and a.status in [:sending, :failed]),
        set: set ++ [updated_at: DateTime.utc_now()]
      )

      Dokkit.Issues.changed(false)
    end

    :ok
  end

  defp reason(%WorkRun{output: output, exit_code: code}) do
    case output |> String.split("\n", trim: true) |> Enum.join("; ") do
      "" -> "The Mac answered with exit code #{code}."
      text -> String.slice(text, 0, 500)
    end
  end

  @test_wait 60_000

  @doc """
  Sends a test. An iMessage goes the way an alert does, and the answer is waited for up to a
  minute; a run nobody picked up by then is withdrawn so it does not send later.
  """
  def test(channel, person \\ nil)

  def test("imessage", person) do
    config = told(config(), person, "imessage")

    with {:ok, mac} <- imessage_mac(config), {:ok, to} <- imessage_to(config) do
      run = Dokkit.Work.imessage(mac.id, to, "A test from Dokkit (dokkit, DOK-0)")
      answer = wait_for(run, mac, Application.get_env(:dokkit, :imessage_test_wait, @test_wait))
      if answer == :ok, do: remember_imessage(mac.id)
      answer
    end
  end

  def test(channel, person) do
    config = told(config(), person, channel)

    about = %{
      id: "test-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
      short: "DOK-0",
      title: "A test from Dokkit",
      note: "If you can read this, the #{channel} channel works.",
      machine: "dokkit",
      state: if(channel == "page", do: :down, else: :degraded),
      url: Dokkit.Certificate.url()
    }

    with :ok <- send_to(provider(channel, config), :open, about, config) do
      if keeps_open?(channel, config), do: stay_open(about.id, channel, person)
      :ok
    end
  end

  @test_stays 120

  @doc "Whether a test by this channel stays open for two minutes: a PagerDuty incident is not noticed if it resolves at once."
  def keeps_open?(channel, config \\ config()),
    do: provider(channel, config) in [:pagerduty_high, :pagerduty_low]

  def test_stays, do: @test_stays

  defp stay_open(id, channel, person) do
    due = DateTime.add(DateTime.utc_now(), @test_stays)

    Repo.insert!(%Setting{
      key: "test_open:" <> id,
      value: %{
        "id" => id,
        "channel" => channel,
        "person" => person && person.id,
        "due" => DateTime.to_iso8601(due),
        "tries" => 0
      }
    })
  end

  @doc """
  Resolves the PagerDuty tests whose two minutes are up. The open tests are rows, so a restart
  in between still sends the resolve on the next sweep. Returns how many resolved.
  """
  def resolve_tests(now \\ DateTime.utc_now()) do
    rows = Repo.all(from s in Setting, where: like(s.key, "test_open:%"))

    for %Setting{value: v} = row <- rows,
        {:ok, due, _} = DateTime.from_iso8601(v["due"]),
        DateTime.compare(due, now) != :gt,
        reduce: 0 do
      n ->
        person = v["person"] && People.get(v["person"])
        config = told(config(), person, v["channel"])
        tries = v["tries"] + 1

        case send_to(provider(v["channel"], config), :close, %{id: v["id"]}, config) do
          :ok ->
            Repo.delete!(row)
            n + 1

          {:error, _} when tries >= @max_attempts ->
            Repo.delete!(row)
            n

          {:error, _} ->
            Repo.update!(Ecto.Changeset.change(row, value: %{v | "tries" => tries}))
            n
        end
    end
  end

  defp told(config, nil, _), do: config
  defp told(config, person, channel), do: People.overlay(config, person, channel)

  defp remember_imessage(machine_id) do
    value = %{"machine" => machine_id, "at" => DateTime.to_iso8601(DateTime.utc_now())}

    Setting.put("imessage_ok", value)
  end

  @doc """
  Where iMessage sending stands: `{:ready, text}` once the chosen Mac has answered a test, else
  `{:missing, text}` saying what is still missing.
  """
  def imessage_status(config \\ config()) do
    mac = imessage_mac(config)
    ok = Setting.get("imessage_ok")

    cond do
      config["imessage_machine"] in [nil, ""] ->
        {:missing, "No Mac is chosen yet."}

      match?({:error, _}, mac) ->
        {:missing, "The Mac that was chosen is not enrolled any more."}

      recipients(config["imessage_to"]) == [] and not any_imessage_address?() ->
        {:missing, "No address is set to send to."}

      ok["machine"] == config["imessage_machine"] ->
        {:ready, "iMessage sending is set up. #{elem(mac, 1).name} answered a test."}

      refused?(elem(mac, 1)) ->
        {:missing,
         "#{elem(mac, 1).name} is chosen but its program has not picked up the test. It must be running, and told it may send with dokkit imessage on."}

      true ->
        {:missing, "#{elem(mac, 1).name} is chosen. Send a test to finish setting it up."}
    end
  end

  defp any_imessage_address?, do: Enum.any?(People.list(), &(&1.imessage not in [nil, ""]))

  defp refused?(mac) do
    match?(
      %WorkRun{state: :refused},
      Repo.one(
        from r in WorkRun,
          where: r.machine_id == ^mac.id and r.name == "dokkit:imessage",
          order_by: [desc: r.inserted_at],
          limit: 1
      )
    )
  end

  defp wait_for(run, mac, left) do
    case Repo.get!(WorkRun, run.id) do
      %WorkRun{state: :ok} ->
        :ok

      %WorkRun{state: state} = r when state in [:fail, :refused] ->
        {:error, reason(r)}

      r when left <= 0 ->
        Repo.update_all(from(x in WorkRun, where: x.id == ^r.id and x.state == :queued),
          set: [state: :refused, finished_at: DateTime.utc_now(), output: "Not picked up."]
        )

        {:error, not_picked_up(mac.name)}

      _ ->
        Process.sleep(250)
        wait_for(run, mac, left - 250)
    end
  end

  defp about(%Issue{} = i) do
    %{
      id: i.id,
      short: Issue.short_id(i),
      title: i.title,
      note: i.check && i.check.note,
      machine: i.machine.name,
      state: i.state,
      url: Dokkit.Certificate.url()
    }
  end

  defp provider("page", _), do: :pagerduty_high
  defp provider("webhook", _), do: :webhook

  defp provider(channel, _) when channel in ~w(email sms text imessage digest),
    do: String.to_atom(channel)

  defp provider("push", %{"push_with" => "pagerduty"}), do: :pagerduty_low
  defp provider("push", %{"push_with" => "pushover"}), do: :pushover
  defp provider("push", _), do: :ntfy

  defp send_to(p, action, about, %{"pagerduty_key" => key})
       when p in [:pagerduty_high, :pagerduty_low] and key not in [nil, ""] do
    body = %{
      routing_key: key,
      dedup_key: "dokkit-#{about.id}",
      event_action: if(action == :open, do: "trigger", else: "resolve")
    }

    body =
      if action == :open do
        payload = %{
          summary: summary(about),
          source: about.machine,
          severity: if(p == :pagerduty_high, do: "critical", else: "warning")
        }

        Map.merge(body, %{payload: payload, links: [%{href: about.url, text: "Open Dokkit"}]})
      else
        body
      end

    post("https://events.pagerduty.com/v2/enqueue", json: body)
  end

  defp send_to(p, _, _, _) when p in [:pagerduty_high, :pagerduty_low],
    do: {:error, "PagerDuty has no routing key yet."}

  defp send_to(:ntfy, :open, about, %{"ntfy_url" => url} = config) when url not in [nil, ""] do
    token = config["ntfy_token"]
    auth = if token in [nil, ""], do: [], else: [{"authorization", "Bearer " <> token}]

    post(url,
      body: about.note || about.title,
      headers: [{"title", summary(about)}, {"priority", "low"}, {"click", about.url}] ++ auth
    )
  end

  defp send_to(:ntfy, :open, _, _), do: {:error, "ntfy has no topic address yet."}

  defp send_to(:pushover, :open, about, %{"pushover_token" => token, "pushover_user" => user})
       when token not in [nil, ""] and user not in [nil, ""] do
    form = [
      token: token,
      user: user,
      title: summary(about),
      message: about.note || about.title,
      priority: -1,
      url: about.url
    ]

    post("https://api.pushover.net/1/messages.json", form: form)
  end

  defp send_to(:pushover, :open, _, _),
    do: {:error, "Pushover needs an application token and a user key."}

  defp send_to(:webhook, action, about, %{"webhook_url" => url}) when url not in [nil, ""] do
    post(url, json: webhook_body(webhook_kind(url), action, about))
  end

  defp send_to(:webhook, _, _, _), do: {:error, "The webhook has no address yet."}

  defp send_to(p, :open, about, config) when p in [:email, :digest] do
    lines = [about.title, about.note, "On #{about.machine}. #{about.short}.", about.url]
    Dokkit.Mail.send(config["email_to"], summary(about), Enum.reject(lines, &is_nil/1), config)
  end

  defp send_to(:sms, :open, about, %{"twilio_sid" => sid, "twilio_token" => token} = config)
       when sid not in [nil, ""] and token not in [nil, ""] do
    from = config["twilio_from"]
    to = recipients(config["sms_to"])

    cond do
      from in [nil, ""] ->
        {:error, "SMS has no number to send from yet."}

      to == [] ->
        {:error, "SMS has no recipients yet."}

      true ->
        url = "https://api.twilio.com/2010-04-01/Accounts/#{sid}/Messages.json"

        to
        |> Enum.map(fn number ->
          form = [To: digits(number), From: digits(from), Body: summary(about)]
          post(url, auth: {:basic, "#{sid}:#{token}"}, form: form, say: true)
        end)
        |> Enum.find(:ok, &(&1 != :ok))
    end
  end

  defp send_to(:sms, :open, _, _), do: {:error, "SMS needs a Twilio account SID and auth token."}

  # ntfy, Pushover and mail have nothing to resolve.
  defp send_to(_, :close, _, _), do: :ok

  defp digits(number), do: String.replace(number, ~r/[ ()\-.]/, "")

  defp summary(about), do: "#{about.title} (#{about.machine}, #{about.short})"

  @discord_hosts ~w(discord.com discordapp.com ptb.discord.com canary.discord.com)

  defp webhook_kind(url) do
    %URI{host: host, path: path} = URI.parse(url)
    host = String.downcase(host || "")

    cond do
      host == "hooks.slack.com" -> :slack
      host in @discord_hosts and (path || "") =~ ~r{^/api/(v\d+/)?webhooks/} -> :discord
      true -> :json
    end
  end

  defp webhook_body(:slack, action, about) do
    esc =
      &(&1
        |> String.replace("&", "&amp;")
        |> String.replace("<", "&lt;")
        |> String.replace(">", "&gt;"))

    %{text: chat_text(action, about, esc, "<#{about.url}|Open Dokkit>")}
  end

  defp webhook_body(:discord, action, about) do
    %{
      content: chat_text(action, about, & &1, "[Open Dokkit](#{about.url})"),
      allowed_mentions: %{parse: []}
    }
  end

  defp webhook_body(:json, action, about) do
    %{
      event: if(action == :open, do: "opened", else: "closed"),
      issue: Map.put(about, :id, about.short) |> Map.delete(:short)
    }
  end

  # The note is cut so a Discord message stays under its 2000 characters.
  defp chat_text(:open, about, esc, link) do
    note = about.note && esc.(String.slice(about.note, 0, 1500))

    Enum.join(
      Enum.reject(["Opened: " <> esc.(summary(about)), note, link], &(&1 in [nil, ""])),
      "\n"
    )
  end

  defp chat_text(:close, about, esc, link),
    do: "Resolved: #{esc.(summary(about))}\n#{link}"

  @local_error "The address points at this machine or a link-local address. Set DOKKIT_ALLOW_LOCAL_ALERTS=1 on the server to allow that."
  @failed "Dokkit could not deliver it there. The server log has the reason."

  @doc "`:ok` for an https address that does not point at this machine or a link-local one."
  def check_url(url) do
    with {:ok, host} <- https_host(url), {:ok, _} <- resolve(host), do: :ok
  end

  defp https_host(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when host not in [nil, ""] -> {:ok, host}
      _ -> {:error, "The address must start with https://."}
    end
  end

  @doc """
  Looks a host name up once. `{:ok, addresses}`, or an error when any address is loopback,
  link-local or unspecified, unless `DOKKIT_ALLOW_LOCAL_ALERTS=1`. A server on a private
  network may send to other hosts on it.
  """
  def resolve(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")
    ips = addrs(host)

    local =
      host == "localhost" or String.ends_with?(host, ".localhost") or Enum.any?(ips, &local_ip?/1)

    if local and System.get_env("DOKKIT_ALLOW_LOCAL_ALERTS") != "1",
      do: {:error, @local_error},
      else: {:ok, ips}
  end

  @doc "The one reason a send failed that is shown to a person. The detail goes to the log."
  def failed(host, detail) do
    Logger.warning("Sending to #{host} failed: #{detail}")
    {:error, @failed}
  end

  defp addrs(host) do
    name = String.to_charlist(host)

    case :inet.parse_address(name) do
      {:ok, ip} -> [ip]
      _ -> for f <- [:inet, :inet6], {:ok, l} <- [:inet.getaddrs(name, f)], ip <- l, do: ip
    end
  end

  # Connects to the address that was checked, so a second lookup cannot answer differently.
  defp pin(url, opts, ips) do
    %URI{host: host} = uri = URI.parse(url)
    host = String.trim_trailing(host, ".")

    with false <- Keyword.has_key?(opts, :plug),
         {:error, _} <- :inet.parse_address(String.to_charlist(host)),
         [ip | _] <- Enum.sort_by(ips, &tuple_size/1) do
      ip = ip |> :inet.ntoa() |> to_string()
      ip = if String.contains?(ip, ":"), do: "[#{ip}]", else: ip

      {URI.to_string(%{uri | host: ip, authority: nil}),
       [connect_options: [hostname: host]] ++ opts}
    else
      _ -> {url, opts}
    end
  end

  defp local_ip?({0, 0, 0, 0}), do: true
  defp local_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp local_ip?({127, _, _, _}), do: true
  defp local_ip?({169, 254, _, _}), do: true
  defp local_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp local_ip?({0, 0, 0, 0, 0, 65535, a, b}),
    do: local_ip?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})

  defp local_ip?({first, _, _, _, _, _, _, _}), do: first in 0xFE80..0xFEBF
  defp local_ip?(_), do: false

  defp post(url, opts) do
    {say, opts} = Keyword.pop(opts, :say, false)

    opts =
      [retry: :transient, max_retries: 2, receive_timeout: 10_000, redirect: false] ++
        opts ++ Application.get_env(:dokkit, :req_options, [])

    with {:ok, host} <- https_host(url), {:ok, ips} <- resolve(host) do
      {pinned, opts} = pin(url, opts, ips)

      case Req.post(pinned, opts) do
        {:ok, %{status: s}} when s in 200..299 ->
          :ok

        {:ok, %{status: s, body: %{"message" => why}}} when say and is_binary(why) ->
          Logger.warning("Sending to #{host} failed: answered #{s}: #{why}")
          {:error, String.slice(why, 0, 500)}

        {:ok, %{status: s}} ->
          failed(host, "answered #{s}")

        {:error, e} ->
          failed(host, Exception.message(e))
      end
    end
  rescue
    e -> failed(url |> URI.parse() |> Map.get(:host), Exception.message(e))
  end
end
