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

  @defaults %{"down" => "page", "degraded" => "push", "push_with" => "ntfy"}
  @secrets ~w(pagerduty_key ntfy_token pushover_token pushover_user smtp_password)
  @plain ~w(ntfy_url webhook_url smtp_host smtp_port smtp_user mail_from email_to text_to digest_at heartbeat_url)
  @max_attempts 5
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

  def secrets, do: @secrets

  def config do
    Map.merge(@defaults, (Repo.get(Setting, "alerts") || %Setting{value: %{}}).value)
  end

  @doc "Saves what was filled in. A secret left blank keeps its stored value."
  def save(params) do
    old = config()

    new =
      for {k, v} <- Map.take(params, Map.keys(@defaults) ++ @secrets ++ @plain),
          into: old do
        v = String.trim(v)
        {k, if(v == "" and k in @secrets, do: old[k], else: v)}
      end

    Repo.insert!(%Setting{key: "alerts", value: new},
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )

    new
  end

  @kinds [{"Anything", ""}, {"A job", "job"}, {"A check", "check"}, {"A machine", "machine"}]
  @states [{"stops or struggles", ""}, {"stops", "down"}, {"struggles", "degraded"}]
  def rule_kinds, do: @kinds
  def rule_states, do: @states

  @doc "Rules, first match first. A service's own routing comes before them, the two defaults after."
  def rules, do: (Repo.get(Setting, "rules") || %Setting{value: %{}}).value["list"] || []

  def add_rule(params) do
    rule = %{
      "id" => Ecto.UUID.generate(),
      "kind" => pick(@kinds, params["kind"]),
      "state" => pick(@states, params["state"]),
      "machine" => String.trim(params["machine"] || ""),
      "channel" => pick(@channels, params["channel"]) || "none",
      "on" => true
    }

    save_rules(rules() ++ [rule])
  end

  def toggle_rule(id),
    do:
      save_rules(
        for r <- rules(), do: if(r["id"] == id, do: Map.update!(r, "on", &(!&1)), else: r)
      )

  def delete_rule(id), do: save_rules(Enum.reject(rules(), &(&1["id"] == id)))

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
  def plan(%Issue{} = issue, %Service{environment: "production"} = service) do
    channel =
      Map.get(service, :"route_#{issue.state}") || ruled(issue, machine_name(issue.machine_id)) ||
        config()[to_string(issue.state)]

    unless Dokkit.Issues.machine_down?(issue.machine_id), do: insert(issue, channel)
  end

  def plan(%Issue{kind: "machine"} = issue, nil),
    do: insert(issue, ruled(issue, machine_name(issue.machine_id)) || config()["down"])

  def plan(_, _), do: nil

  defp insert(issue, channel) do
    if sends?(channel),
      do: Repo.insert!(%Alert{issue_id: issue.id, channel: channel})
  end

  def closing(%Issue{id: id}) do
    Repo.update_all(
      from(a in Alert, where: a.issue_id == ^id and a.status in [:pending, :failed]),
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
          a.status in [:pending, :closing] or (a.status == :failed and a.attempts < @max_attempts),
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

  defp post(url, opts) do
    opts =
      [retry: :transient, max_retries: 2, receive_timeout: 10_000] ++
        opts ++ Application.get_env(:dokkit, :req_options, [])

    case Req.post(url, opts) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      {:ok, %{status: s}} -> {:error, "#{URI.parse(url).host} answered #{s}."}
      {:error, e} -> {:error, "#{URI.parse(url).host}: #{Exception.message(e)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
