defmodule Dokkit.Alerts do
  @moduledoc """
  Tells people about issues. An issue alerts once, when it opens, and what it raised is
  resolved when it closes. Rows are written with the issue and sent afterwards, so a
  restart or a failed send loses nothing.
  """
  use GenServer
  import Ecto.Query
  require Logger
  alias Dokkit.{Alert, Issue, Repo, Service, Setting}

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
  @secrets ~w(pagerduty_key ntfy_token pushover_token pushover_user smtp_password)
  @plain ~w(disk_limit memory_limit ntfy_url webhook_url smtp_host smtp_port smtp_user mail_from email_to text_to digest_at heartbeat_url)
  @max_attempts 5
  @kept_blank ~w(disk_limit memory_limit)
  @channels [
    {"Page", "page"},
    {"Push", "push"},
    {"Email", "email"},
    {"Text", "text"},
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
    "text" => "Texted",
    "webhook" => "Webhook called"
  }

  @doc "What is said of an alert that went out by this channel, or nil."
  def sent_word(channel), do: @sent[channel]

  def secrets, do: @secrets

  def config do
    Map.merge(@defaults, unblank((Repo.get(Setting, "alerts") || %Setting{value: %{}}).value))
  end

  # A blank value falls back to its default; a blank limit switches that limit off.
  defp unblank(map),
    do: Map.reject(map, fn {k, v} -> v == "" and k not in @secrets and k not in @kept_blank end)

  @doc "Saves what was filled in. A secret left blank keeps its stored value."
  def save(params) do
    old = config()

    new =
      for({k, v} <- Map.take(params, Map.keys(@defaults) ++ @secrets ++ @plain), into: old) do
        v = String.trim(v)
        {k, if(v == "" and k in @secrets, do: old[k], else: v)}
      end
      |> unblank()

    Repo.insert!(%Setting{key: "alerts", value: new},
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )

    new
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

  @doc "When the night ends, as it is said on the Alerts page."
  def night_ends(config \\ config()),
    do:
      night_hour(config, "night_to", 0..23)
      |> to_string()
      |> String.pad_leading(2, "0")
      |> Kernel.<>(":00")

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
      "machine" => String.trim(params["machine"] || ""),
      "channel" => pick(@channels, params["channel"]) || "none",
      "on" => true
    }
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
  def wake(%Service{id: id}) do
    Repo.update_all(
      from(a in Alert,
        join: i in assoc(a, :issue),
        where: a.status == :held and i.service_id == ^id and is_nil(i.closed_at)
      ),
      set: [status: :pending]
    )
  end

  @doc "An alert that never went out is sent after all when its issue comes back."
  def reopened(%Issue{id: id} = issue) do
    held = Repo.preload(issue, :service).service |> holds?("page", DateTime.utc_now())

    Repo.update_all(from(a in Alert, where: a.issue_id == ^id and a.status == :skipped),
      set: [status: :pending, attempts: 0, error: nil]
    )

    if held,
      do:
        Repo.update_all(
          from(a in Alert,
            where: a.issue_id == ^id and a.status == :pending and a.channel != "digest"
          ),
          set: [status: :held]
        )
  end

  def closing(%Issue{id: id}) do
    Repo.update_all(
      from(a in Alert, where: a.issue_id == ^id and a.status in [:pending, :failed, :held]),
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

      change =
        case send_to(provider(alert.channel, config), action, about(alert.issue), config) do
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

  def test(channel) do
    config = config()

    about = %{
      id: "test",
      short: "DOK-0",
      title: "A test from Dokkit",
      note: "If you can read this, the #{channel} channel works.",
      machine: "dokkit",
      state: if(channel == "page", do: :down, else: :degraded),
      url: DokkitWeb.Endpoint.url()
    }

    provider = provider(channel, config)

    with :ok <- send_to(provider, :open, about, config) do
      if provider in [:pagerduty_high, :pagerduty_low],
        do: send_to(provider, :close, about, config),
        else: :ok
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
      url: DokkitWeb.Endpoint.url()
    }
  end

  defp provider("page", _), do: :pagerduty_high
  defp provider("webhook", _), do: :webhook
  defp provider(channel, _) when channel in ~w(email text digest), do: String.to_atom(channel)
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

  # A text is short, and the address that turns mail into one decides how short.
  defp send_to(:text, :open, about, config),
    do: Dokkit.Mail.send(config["text_to"], "Dokkit", [summary(about)], config)

  # ntfy, Pushover and mail have nothing to resolve.
  defp send_to(_, :close, _, _), do: :ok

  defp summary(about), do: "#{about.title} (#{about.machine}, #{about.short})"

  @doc "`:ok` for an https address that is not this machine or a link-local one."
  def check_url(url) do
    %URI{scheme: scheme, host: host} = URI.parse(url)

    cond do
      scheme != "https" or host in [nil, ""] -> {:error, "The address must start with https://."}
      local?(host) -> {:error, "The address points at this machine or its own network."}
      true -> :ok
    end
  end

  defp local?(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    host == "localhost" or String.ends_with?(host, ".localhost") or
      Enum.any?(addrs(host), &local_ip?/1)
  end

  defp addrs(host) do
    name = String.to_charlist(host)

    case :inet.parse_address(name) do
      {:ok, ip} -> [ip]
      _ -> for f <- [:inet, :inet6], {:ok, l} <- [:inet.getaddrs(name, f)], ip <- l, do: ip
    end
  end

  # Connects to the address that was checked, so a second lookup cannot answer differently.
  defp pin(url, opts) do
    %URI{host: host} = uri = URI.parse(url)
    host = String.trim_trailing(host, ".")

    with false <- Keyword.has_key?(opts, :plug),
         {:error, _} <- :inet.parse_address(String.to_charlist(host)),
         [ip | _] <- Enum.sort_by(addrs(host), &tuple_size/1) do
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
    opts =
      [retry: :transient, max_retries: 2, receive_timeout: 10_000, redirect: false] ++
        opts ++ Application.get_env(:dokkit, :req_options, [])

    with :ok <- check_url(url) do
      host = URI.parse(url).host
      {url, opts} = pin(url, opts)

      case Req.post(url, opts) do
        {:ok, %{status: s}} when s in 200..299 -> :ok
        {:ok, %{status: s}} -> {:error, "#{host} answered #{s}."}
        {:error, e} -> {:error, "#{host}: #{Exception.message(e)}"}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
