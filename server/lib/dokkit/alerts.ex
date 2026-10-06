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
  @secrets ~w(pagerduty_key ntfy_token pushover_token pushover_user)
  @max_attempts 5

  def secrets, do: @secrets

  def config do
    Map.merge(@defaults, (Repo.get(Setting, "alerts") || %Setting{value: %{}}).value)
  end

  @doc "Saves what was filled in. A secret left blank keeps its stored value."
  def save(params) do
    old = config()

    new =
      for {k, v} <- Map.take(params, Map.keys(@defaults) ++ @secrets ++ ~w(ntfy_url webhook_url)),
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

  # A machine that is down alerts once for itself. What runs on it stays quiet until it is back.
  def plan(%Issue{} = issue, %Service{environment: "production"} = service) do
    channel = Map.get(service, :"route_#{issue.state}") || config()[to_string(issue.state)]
    unless Dokkit.Issues.machine_down?(issue.machine_id), do: insert(issue, channel)
  end

  def plan(%Issue{kind: "machine"} = issue, nil), do: insert(issue, config()["down"])
  def plan(_, _), do: nil

  defp insert(issue, channel) do
    if channel in ~w(page push webhook),
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

  # ntfy and Pushover have nothing to resolve.
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
