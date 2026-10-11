defmodule Dokkit.Alerts do
  @moduledoc """
  Tells people about issues. An issue alerts once, when it opens, and what it raised is
  resolved when it closes. Rows are written with the issue and sent afterwards, so a
  restart or a failed send loses nothing.
  """
  use GenServer
  import Ecto.Query
  require Logger
  alias Dokkit.{Alert, Issue, Machine, Repo, Service, Setting, TaskRun}

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
  @plain ~w(disk_limit memory_limit ntfy_url webhook_url smtp_host smtp_port smtp_user mail_from email_to digest_at heartbeat_url imessage_machine imessage_to twilio_sid twilio_from sms_to)
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
    Map.merge(@defaults, unblank((Repo.get(Setting, "alerts") || %Setting{value: %{}}).value))
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
        {k, String.trim(v)}
      end
      |> Map.merge(Map.new(gone, &{&1, ""}))
      |> unblank()

    Repo.insert!(%Setting{key: "alerts", value: new},
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )

    new
  end

  def setting_keys, do: Map.keys(@defaults) ++ @secrets ++ @plain

  @hidden @secrets ++ ~w(ntfy_url webhook_url heartbeat_url smtp_user twilio_sid)

  @doc "The settings as the API shows them: addresses, user names and secrets are only set or not set."
  def view do
    c = config()
    marks = Map.new(@hidden, &{&1, if(c[&1] in [nil, ""], do: "not set", else: "set")})
    c |> Map.drop(@hidden) |> Map.merge(marks)
  end

  @doc """
  Checks the settings, then saves them. `{:ok, config, note}` or `{:error, text}`. The note says
  which secrets the save cleared because their address changed, or is nil.
  """
  def update(params) do
    params = Map.take(params, setting_keys())

    cond do
      Enum.any?(params, fn {_, v} -> not is_binary(v) end) ->
        {:error, "Every setting is text."}

      error =
          bad_choice(params) || night_error(params) || bad_recipients(params) ||
            bad_address(params) ->
        {:error, error}

      true ->
        note = cleared_note(cleared(params))
        {:ok, save(params), note}
    end
  end

  defp bad_choice(params) do
    channels = for {_, v} <- @channels, do: v

    Enum.find_value(
      %{"down" => channels, "degraded" => channels, "push_with" => ~w(ntfy pushover pagerduty)},
      fn {k, ok} ->
        if String.trim(params[k] || "") not in ["" | ok],
          do: "#{k} is one of #{Enum.join(ok, ", ")}."
      end
    )
  end

  @phone ~r/^\+?[0-9][0-9 ()\-.]{5,19}$/
  @email ~r/^[^@\s,]+@[^@\s,]+\.[^@\s,]+$/

  @doc "The recipients written in a setting, commas between them."
  def recipients(value),
    do: (value || "") |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp bad_recipients(params) do
    bad_mac(params) ||
      Enum.find_value(
        [{"imessage_to", [@phone, @email]}, {"sms_to", [@phone]}, {"twilio_from", [@phone]}],
        fn {k, ok} ->
          Enum.find_value(recipients(params[k]), fn r ->
            unless Enum.any?(ok, &Regex.match?(&1, r)),
              do:
                "#{k}: #{r} is not a #{if length(ok) == 2, do: "phone number or an email address", else: "phone number"}."
          end)
        end
      ) || bad_sid(params)
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

  # No time zone database is installed, so the night is set in hours from UTC.
  @doc "Whether `now` falls in the night set on the Alerts page."
  def night?(now, config \\ config()) do
    from = night_hour(config, "night_from", 0..23)
    to = night_hour(config, "night_to", 0..23)
    hour = Integer.mod(now.hour + night_hour(config, "night_offset", -12..14), 24)
    if from <= to, do: hour >= from and hour < to, else: hour >= from or hour < to
  end

  defp night_hour(config, key, range) do
    whole_hour(config[key], range) || String.to_integer(@defaults[key])
  end

  defp whole_hour(value, range) do
    case Integer.parse(value || "") do
      {n, ""} -> if n in range, do: n
      _ -> nil
    end
  end

  @doc "When the night ends, in the night's own offset, such as \"07:00 UTC+2\"."
  def night_ends(config \\ config()) do
    hour = night_hour(config, "night_to", 0..23) |> to_string() |> String.pad_leading(2, "0")
    offset = night_hour(config, "night_offset", -12..14)
    "#{hour}:00 UTC#{if offset > 0, do: "+#{offset}", else: if(offset < 0, do: offset)}"
  end

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
  def rules, do: (Repo.get(Setting, "rules") || %Setting{value: %{}}).value["list"] || []

  def add_rule(params),
    do: save_rules(rules() ++ [Map.merge(rule(params), %{"id" => Ecto.UUID.generate()})])

  @doc "Changes what a rule says; a field that is not given stays as it was. Its place in the order stays."
  def update_rule(id, params) do
    save_rules(
      for r <- rules() do
        if r["id"] == id do
          given = Map.take(rule(params), Map.keys(params))
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
      "channel" => if((c = pick(@channels, params["channel"])) == "", do: "none", else: c),
      "on" => true
    }
  end

  @doc "An error for a rule whose fields are not text, a known word, or true or false; else nil."
  def rule_error(params) do
    words = %{"kind" => @kinds, "state" => @states, "channel" => @channels}

    Enum.find_value(~w(kind state channel machine on), fn k ->
      v = params[k]

      cond do
        not Map.has_key?(params, k) ->
          nil

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

  def delete_rule(id), do: save_rules(Enum.reject(rules(), &(&1["id"] == id)))

  @often 6

  @doc """
  Changes worth offering: an issue that has opened six times or more in a month and is
  snoozed, while its service still sends somewhere louder than the digest. Nothing here
  changes a rule; a person accepts or dismisses.
  """
  def suggestions do
    dismissed =
      (Repo.get(Setting, "suggestions") || %Setting{value: %{}}).value["dismissed"] || []

    since = DateTime.add(DateTime.utc_now(), -30 * 86_400)

    Repo.all(
      from i in Issue,
        join: s in assoc(i, :service),
        where: i.count >= @often and not is_nil(i.snoozed_until) and i.since > ^since,
        where: s.id not in ^dismissed,
        order_by: [desc: i.count],
        preload: [service: s]
    )
    |> Enum.reject(&(route(&1.service, &1.state) == "digest"))
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
      old = (Repo.get(Setting, "suggestions") || %Setting{value: %{}}).value["dismissed"] || []

      Repo.insert!(%Setting{key: "suggestions", value: %{"dismissed" => [i.service_id | old]}},
        on_conflict: {:replace, [:value, :updated_at]},
        conflict_target: :key
      )
    end
  end

  defp pick(options, value), do: Enum.find_value(options, "", fn {_, v} -> v == value && v end)

  defp save_rules(list) do
    Repo.insert!(%Setting{key: "rules", value: %{"list" => list}},
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )

    list
  end

  defp ruled(%Issue{} = issue, machine) do
    kind = if issue.kind in ~w(job machine), do: issue.kind, else: "check"

    Enum.find_value(rules(), fn r ->
      (r["on"] and r["kind"] in ["", kind] and r["state"] in ["", to_string(issue.state)] and
         r["machine"] in ["", machine]) && r["channel"]
    end)
  end

  defp machine_name(id),
    do: Repo.one(from m in Dokkit.Machine, where: m.id == ^id, select: m.name)

  # A machine that is down alerts once for itself. What runs on it stays quiet until it is back.
  def plan(issue, service, now \\ DateTime.utc_now())

  def plan(%Issue{} = issue, %Service{environment: "production"} = service, now) do
    # A soon issue never takes a rule, and never pages: a page for it goes as a push.
    channel =
      Map.get(service, :"route_#{issue.state}") ||
        (!issue.soon && ruled(issue, machine_name(issue.machine_id))) ||
        config()[to_string(issue.state)]

    channel = if issue.soon and channel == "page", do: "push", else: channel

    unless Dokkit.Issues.machine_down?(issue.machine_id) do
      insert(issue, channel, if(holds?(service, channel, now), do: :held, else: :pending))
    end
  end

  def plan(%Issue{kind: "machine"} = issue, nil, _),
    do: insert(issue, ruled(issue, machine_name(issue.machine_id)) || config()["down"], :pending)

  def plan(_, _, _), do: nil

  # A held alert waits in the database for the sweep after the night ends.
  defp holds?(%Service{night: false}, channel, now), do: channel != "digest" and night?(now)
  defp holds?(_, _, _), do: false

  defp insert(issue, channel, status) do
    if sends?(channel),
      do: Repo.insert!(%Alert{issue_id: issue.id, channel: channel, status: status})
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
  """
  def reopened(%Issue{id: id} = issue, now \\ DateTime.utc_now()) do
    held = Repo.preload(issue, :service).service |> holds?("page", now)
    live = is_nil(issue.acknowledged_at) and not snoozed?(issue, now)

    Repo.update_all(from(a in Alert, where: a.issue_id == ^id and a.status == :skipped),
      set: [status: :pending, attempts: 0, error: nil]
    )

    Repo.update_all(
      from(a in Alert, where: a.issue_id == ^id and a.status == :closing and a.attempts == 0),
      set: [status: :sent]
    )

    resolved = from(a in Alert, where: a.issue_id == ^id and a.status in [:closing, :closed])
    resolving = if config()["push_with"] == "pagerduty", do: ["page", "push"], else: ["page"]

    if live,
      do:
        Repo.update_all(from(a in resolved, where: a.channel in ^resolving),
          set: [status: :pending, attempts: 0, error: nil]
        )

    Repo.update_all(from(a in resolved, where: a.channel not in ^resolving), set: [status: :sent])

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
        preload: [issue: [:machine, :check]]
    )
    |> Enum.map(fn alert ->
      action = if alert.status == :closing, do: :close, else: :open

      about = about(alert.issue)

      sent =
        if alert.channel == "imessage" and action == :open,
          do: imessage(alert, about, config),
          else: send_to(provider(alert.channel, config), action, about, config)

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
          from r in TaskRun,
            where: r.alert_id == ^alert.id,
            order_by: [desc: r.inserted_at],
            limit: 1
        )

      case last do
        %TaskRun{state: state} when state in [:queued, :running] ->
          if stale?(last, DateTime.utc_now()),
            do: {:error, not_picked_up(mac.name)},
            else: :waiting

        _ ->
          Dokkit.Tasks.imessage(mac.id, to, summary(about), alert.id)
          :waiting
      end
    end
  end

  defp stale?(%TaskRun{inserted_at: at}, now), do: DateTime.diff(now, at) >= @imessage_wait

  @doc """
  Fails the iMessage alerts whose Mac has not answered in five minutes. Their run stays, so a
  late answer still counts and a retry does not send a second message. Returns how many failed.
  """
  def settle(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@imessage_wait)

    late =
      Repo.all(
        from a in Alert,
          join: r in TaskRun,
          on: r.alert_id == a.id and r.state in [:queued, :running],
          join: t in assoc(r, :task),
          join: m in assoc(t, :machine),
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
    with %TaskRun{alert_id: id} = run when is_binary(id) <- Repo.get(TaskRun, run_id) do
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

  defp reason(%TaskRun{output: output, exit_code: code}) do
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
  def test("imessage") do
    config = config()

    with {:ok, mac} <- imessage_mac(config), {:ok, to} <- imessage_to(config) do
      run = Dokkit.Tasks.imessage(mac.id, to, "A test from Dokkit (dokkit, DOK-0)")
      wait_for(run, mac, Application.get_env(:dokkit, :imessage_test_wait, @test_wait))
    end
  end

  def test(channel) do
    config = config()

    about = %{
      id: "test",
      short: "DOK-0",
      title: "A test from Dokkit",
      note: "If you can read this, the #{channel} channel works.",
      machine: "dokkit",
      state: if(channel == "page", do: :down, else: :degraded),
      url: Dokkit.Certificate.url()
    }

    provider = provider(channel, config)

    with :ok <- send_to(provider, :open, about, config) do
      if provider in [:pagerduty_high, :pagerduty_low],
        do: send_to(provider, :close, about, config),
        else: :ok
    end
  end

  defp wait_for(run, mac, left) do
    case Repo.get!(TaskRun, run.id) do
      %TaskRun{state: :ok} ->
        :ok

      %TaskRun{state: state} = r when state in [:fail, :refused] ->
        {:error, reason(r)}

      r when left <= 0 ->
        Repo.update_all(from(x in TaskRun, where: x.id == ^r.id and x.state == :queued),
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
    post(url,
      json: %{
        event: if(action == :open, do: "opened", else: "closed"),
        issue: Map.put(about, :id, about.short) |> Map.delete(:short)
      }
    )
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
