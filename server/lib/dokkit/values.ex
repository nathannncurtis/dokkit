defmodule Dokkit.Values do
  @moduledoc """
  Every operational value Dokkit decides by itself. Each keeps today's value as its default and
  can be changed for the whole server; a machine's values can be changed for that machine and a
  job's for that job. A scope is `:server`, `{:machine, id}` or `{:job, service_id}`.
  """
  alias Dokkit.{Repo, Setting}

  @rows [
    %{
      group: "machines",
      id: "disk",
      scope: :machine,
      title: "Disk space",
      sub:
        "Tell me when a disk fills up. A threshold in a dokkit.toml replaces the default, and a machine's own setting replaces both.",
      toggle: {"disk_on", true},
      fields: [{"disk_limit", 90, 1, 100}, {"disk_after", 3, 1, 100}, {"disk_down", 98, 1, 100}],
      words: ["Slow at", "% for", "readings in a row, down at", "%"]
    },
    %{
      group: "machines",
      id: "memory",
      scope: :machine,
      title: "Memory",
      sub: "Tell me when memory runs short.",
      toggle: {"memory_on", true},
      fields: [
        {"memory_limit", 95, 1, 100},
        {"memory_after", 3, 1, 100},
        {"memory_down", 98, 1, 100}
      ],
      words: ["Slow at", "% for", "readings in a row, down at", "%"]
    },
    %{
      group: "machines",
      id: "cpu",
      scope: :machine,
      title: "Processor",
      sub: "Tell me when the processor stays busy..",
      toggle: {"cpu_on", true},
      fields: [{"cpu_limit", 90, 1, 100}, {"cpu_minutes", 10, 1, 1440}],
      words: ["Slow at", "% for", "minutes"]
    },
    %{
      group: "machines",
      id: "silent",
      scope: :machine,
      title: "Gone quiet",
      sub: "A machine that stops reporting counts as down after this long.",
      fields: [{"silent_minutes", 3, 1, 1440}],
      words: ["After", "minutes"]
    },
    %{
      group: "machines",
      id: "forecast",
      scope: :machine,
      title: "Disk forecast",
      sub:
        "Warn ahead of time when a disk is on course to fill. The warning stays until the disk is further away than the second number, and a full disk says when it fills if that is soon enough.",
      fields: [
        {"forecast_days", 14, 1, 365},
        {"forecast_clear_days", 16, 1, 365},
        {"forecast_full_days", 60, 1, 3650}
      ],
      words: ["When full within", "days, until more than", "days away. Say when within", "days"]
    },
    %{
      group: "machines",
      id: "forecast_readings",
      scope: :server,
      title: "Forecast readings",
      sub: "How much of a disk's history a forecast needs, and how far back it looks.",
      fields: [{"forecast_min_days", 4, 1, 60}, {"forecast_window_days", 7, 2, 60}],
      words: ["Needs", "days of readings, from the last", "days"]
    },
    %{
      group: "machines",
      id: "report",
      scope: :machine,
      title: "Reporting",
      sub:
        "How often the program on the machine sends its heartbeat and readings, and reads its records of jobs.",
      fields: [{"report_seconds", 60, 10, 3600}],
      words: ["Every", "seconds"]
    },
    %{
      group: "machines",
      id: "scan",
      scope: :machine,
      title: "Scanning",
      sub: "How often the machine looks for new services, ports and jobs.",
      fields: [{"scan_first_minutes", 2, 1, 1440}, {"scan_every_hours", 24, 1, 720}],
      words: ["First", "minutes after it starts, then every", "hours"]
    },
    %{
      group: "machines",
      id: "quiet",
      scope: :server,
      title: "Planned downtime",
      sub: "The longest planned downtime, and the lengths offered when you start one.",
      fields: [{"quiet_max_hours", 4, 1, 168}, {"quiet_choices", "15m, 30m, 1h, 2h, 4h", :text}],
      words: ["At most", "hours. Offer", ""]
    },
    %{
      group: "checks",
      id: "fail",
      scope: :server,
      title: "Down after",
      sub:
        "How many failures in a row before a check counts as down, for checks that do not say.",
      fields: [{"check_fail_after", 3, 1, 100}],
      words: ["", "failures in a row"]
    },
    %{
      group: "checks",
      id: "every",
      scope: :server,
      title: "How often",
      sub: "Time between checks that do not say.",
      fields: [{"check_every_seconds", 30, 1, 86_400}],
      words: ["Every", "seconds"]
    },
    %{
      group: "checks",
      id: "timeout",
      scope: :server,
      title: "Give up after",
      sub: "How long one check may take, for checks that do not say.",
      fields: [{"check_timeout_seconds", 5, 1, 600}],
      words: ["", "seconds"]
    },
    %{
      group: "checks",
      id: "expiry",
      scope: :server,
      title: "Certificates",
      sub: "Warn ahead of a watched certificate running out.",
      fields: [{"expiry_days", 30, 1, 365}],
      words: ["", "days before"]
    },
    %{
      group: "checks",
      id: "restart",
      scope: :server,
      title: "Restarts",
      sub: "Shortest gap between automatic restarts of a service.",
      fields: [{"restart_gap_minutes", 10, 1, 1440}],
      words: ["At least", "minutes apart"]
    },
    %{
      group: "checks",
      id: "beats",
      scope: :server,
      title: "Heartbeats",
      sub:
        "An app's heartbeat counts as gone quiet after this many beats are missed, and a little more.",
      fields: [{"beat_misses", 2, 1, 100}, {"beat_slack_seconds", 60, 0, 3600}],
      words: ["After", "missed beats and", "seconds"]
    },
    %{
      group: "checks",
      id: "reopen",
      scope: :server,
      title: "Same issue",
      sub: "A problem that comes back this soon reopens the old issue instead of a new one.",
      fields: [{"reopen_minutes", 30, 0, 1440}],
      words: ["Within", "minutes"]
    },
    %{
      group: "checks",
      id: "warmup",
      scope: :server,
      title: "After Dokkit restarts",
      sub: "Give machines and jobs time to report before judging them.",
      fields: [{"warmup_minutes", 3, 0, 60}],
      words: ["Wait", "minutes"]
    },
    %{
      group: "jobs",
      id: "grace",
      scope: :job,
      title: "Late",
      sub: "How long after its start time a run can begin before it counts as missed.",
      fields: [{"job_grace_minutes", 30, 0, 10_080}],
      words: ["Grace of", "minutes"]
    },
    %{
      group: "jobs",
      id: "max",
      scope: :job,
      title: "Too long",
      sub: "A run going past this is flagged. A job with its own max_runtime has this on.",
      toggle: {"job_max_on", false},
      fields: [{"job_max_minutes", 60, 1, 10_080}],
      words: ["After", "minutes"]
    },
    %{
      group: "jobs",
      id: "missed",
      scope: :job,
      title: "Missed runs",
      sub: "Tell me when a run does not happen.",
      toggle: {"job_missed", true},
      fields: [],
      words: []
    },
    %{
      group: "jobs",
      id: "history",
      scope: :job,
      title: "History",
      sub:
        "How long runs and their output are kept. The newest run and the newest good run always stay.",
      fields: [{"job_keep_days", 90, 1, 3650}],
      words: ["Keep", "days"]
    },
    %{
      group: "logs",
      id: "restored",
      scope: :server,
      title: "Restored archives",
      sub: "How long a month loaded back from its archive stays searchable.",
      fields: [{"restored_days", 7, 1, 365}],
      words: ["", "days"]
    },
    %{
      group: "logs",
      id: "longest",
      scope: :server,
      title: "Longest line",
      sub: "Longer lines are cut.",
      fields: [{"longest_line_kb", 64, 1, 1024}],
      words: ["", "KB"]
    },
    %{
      group: "errors",
      id: "burst",
      scope: :server,
      title: "Error alerts",
      sub: "Open an issue when a service's errors burst..",
      toggle: {"error_alert_on", true},
      fields: [{"error_alert_count", 10, 1, 100_000}, {"error_alert_minutes", 15, 1, 1440}],
      words: ["When", "errors arrive within", "minutes"]
    },
    %{
      group: "errors",
      id: "stored",
      scope: :server,
      title: "Stored",
      sub: "How many reports of one error are kept in full.",
      fields: [{"errors_first", 100, 1, 100_000}, {"errors_every", 100, 1, 100_000}],
      words: ["The first", ", then one in every", ""]
    },
    %{
      group: "alerts",
      id: "remind",
      scope: :server,
      title: "Remind me",
      sub:
        "Alert again while an issue stays open and nobody has seen it. Not at night, and not by page, since PagerDuty keeps its own incident open..",
      toggle: {"remind_on", true},
      fields: [{"remind_minutes", 30, 5, 1440}],
      words: ["Every", "minutes"]
    },
    %{
      group: "alerts",
      id: "snooze",
      scope: :server,
      title: "Snooze choices",
      sub: "The lengths offered when you snooze, such as 30m, 4h, 1d or 1w.",
      fields: [{"snooze_choices", "1h, 4h, 1d, 1w", :text}],
      words: [""]
    },
    %{
      group: "alerts",
      id: "suggest",
      scope: :server,
      title: "Too noisy?",
      sub: "Suggest moving a check to the digest when its issue keeps opening.",
      fields: [{"suggest_count", 6, 1, 1000}, {"suggest_days", 30, 1, 365}],
      words: ["After", "times in", "days"]
    },
    %{
      group: "alerts",
      id: "tries",
      scope: :server,
      title: "Sending",
      sub: "How many times one alert is tried before it counts as failed.",
      fields: [{"send_tries", 5, 1, 20}],
      words: ["Try", "times"]
    },
    %{
      group: "alerts",
      id: "imessage",
      scope: :server,
      title: "iMessage wait",
      sub: "How long the Mac has to pick up an iMessage before it counts as failed.",
      fields: [{"imessage_wait_seconds", 300, 30, 3600}],
      words: ["", "seconds"]
    },
    %{
      group: "alerts",
      id: "test",
      scope: :server,
      title: "Test alerts",
      sub:
        "How long a test that opens something, such as a page, stays open before it is resolved.",
      fields: [{"test_open_seconds", 120, 10, 3600}],
      words: ["", "seconds"]
    },
    %{
      group: "server",
      id: "session",
      scope: :server,
      title: "Stay signed in",
      sub: "How long a sign-in lasts.",
      fields: [{"session_days", 14, 1, 365}],
      words: ["", "days"]
    },
    %{
      group: "server",
      id: "metrics",
      scope: :server,
      title: "Readings",
      sub: "How long numbers from machines and services are kept.",
      fields: [{"metrics_days", 30, 1, 3650}],
      words: ["", "days"]
    },
    %{
      group: "server",
      id: "processes",
      scope: :server,
      title: "Process lists",
      sub: "How long the top-processes snapshots are kept.",
      fields: [{"processes_hours", 24, 1, 720}],
      words: ["", "hours"]
    },
    %{
      group: "server",
      id: "slots",
      scope: :server,
      title: "Heard from",
      sub: "How long the record of which half hours each machine reported is kept.",
      fields: [{"slots_days", 30, 1, 3650}],
      words: ["", "days"]
    },
    %{
      group: "server",
      id: "hosts",
      scope: :server,
      title: "Unknown machines",
      sub:
        "Hosts named by apps that never enrolled, and own nothing, are forgotten after this long unseen.",
      fields: [{"hosts_days", 30, 1, 3650}],
      words: ["", "days"]
    },
    %{
      group: "server",
      id: "cert",
      scope: :server,
      title: "Own certificate",
      sub: "Warn before this server's certificate runs out.",
      fields: [{"cert_warn_days", 21, 1, 365}],
      words: ["", "days before"]
    },
    %{
      group: "server",
      id: "acme",
      scope: :server,
      title: "Renewing",
      sub:
        "When a certificate Dokkit gets by itself is renewed, and how soon a failed try is made again.",
      fields: [{"acme_renew_days", 30, 1, 60}, {"acme_retry_hours", 12, 1, 168}],
      words: ["", "days before it runs out, again after", "hours"]
    },
    %{
      group: "server",
      id: "self",
      scope: :server,
      title: "Nothing reporting",
      sub: "Alarm when no machine has reported for this long.",
      fields: [{"self_quiet_minutes", 10, 1, 1440}],
      words: ["", "minutes"]
    },
    %{
      group: "server",
      id: "enrol",
      scope: :server,
      title: "Add-a-machine codes",
      sub: "How long a new enrolment code works, and the longest anyone may ask for.",
      fields: [{"enrol_hours", 4, 1, 720}, {"enrol_max_hours", 72, 1, 720}],
      words: ["", "hours, at most", "hours"]
    },
    %{
      group: "server",
      id: "logins",
      scope: :server,
      title: "Sign-in attempts",
      sub:
        "Tries allowed in ten minutes. Over the first two, sign-in is refused; over the third, it slows down.",
      fields: [
        {"login_pair", 10, 1, 1000},
        {"login_address", 30, 1, 1000},
        {"login_name", 10, 1, 1000}
      ],
      words: ["", "for a name from one address,", "from one address,", "for one name"]
    },
    %{
      group: "server",
      id: "updates",
      scope: :server,
      title: "Updates",
      sub:
        "How long a machine has to report back after an update starts, and how long its updater may take: at most 55 minutes, since Windows stops the updater task after an hour.",
      fields: [{"update_run_minutes", 50, 1, 1440}, {"updater_minutes", 45, 1, 55}],
      words: ["", "minutes to report,", "minutes to install"]
    }
  ]

  @groups [
    {"alerts", "bell-ringing", "Alerts",
     "When alerts go again, what is offered, and how sending is tried."},
    {"machines", "hard-drives", "Defaults for every machine",
     "Each machine can change these on its own page."},
    {"checks", "pulse", "Checks",
     "How services are checked unless a dokkit.toml says otherwise."},
    {"jobs", "clock-countdown", "Defaults for every job",
     "Each job can change these on the Jobs page."},
    {"logs", "scroll", "Logs", "Archives and the longest line."},
    {"errors", "bug", "Errors", "What is kept, and when a burst of errors alerts."},
    {"server", "gear-six", "Server", "Housekeeping and sign-in."}
  ]

  # These two live on the Alerts page too, where a blank limit switches it off.
  @alerts %{"disk" => {"disk_on", "disk_limit"}, "memory" => {"memory_on", "memory_limit"}}

  def rows, do: @rows
  def groups, do: @groups

  @doc "The rows shown for a scope: the server sees them all, a machine or a job its own."
  def rows(group, scope) do
    for r <- @rows, r.group == group, shown?(r, scope), do: r
  end

  defp shown?(_, :server), do: true
  defp shown?(r, {kind, _}), do: r.scope == kind

  defp fields(r), do: if(r[:toggle], do: [r.toggle | r.fields], else: r.fields)

  @fields Enum.flat_map(@rows, fn r ->
            Enum.map(
              if(r[:toggle], do: [r.toggle | r.fields], else: r.fields),
              &{elem(&1, 0), {&1, r}}
            )
          end)
          |> Map.new()

  def keys, do: Map.keys(@fields)
  def defaults, do: Map.new(@fields, fn {k, {f, _}} -> {k, elem(f, 1)} end)
  def default(key), do: elem(elem(@fields[key], 0), 1)

  @doc "One value as it applies to the scope."
  def get(key, scope \\ :server), do: Map.fetch!(all(scope), key)

  @table :dokkit_values

  def init, do: :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

  @doc "Every value as it applies to the scope, read through a cache of a few seconds that a save empties."
  def all(scope \\ :server), do: elem(cached(scope), 0)

  @doc "What was changed for exactly this scope."
  def own(scope), do: elem(cached(scope), 1)

  @doc "Empties the cache, after anything that changes a value."
  def forget do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Hot paths (each metric line, request, error report and job) read values; the cache keeps that off the database.
  defp cached(scope) do
    ttl = Application.get_env(:dokkit, :values_cache_ms, 5000)
    now = System.monotonic_time(:millisecond)

    case ttl > 0 && :ets.lookup(@table, scope) do
      [{_, pair, at}] when now - at < ttl ->
        pair

      _ ->
        own = own_now(scope)
        pair = {Map.merge(base(scope), own), own}
        if ttl > 0, do: :ets.insert(@table, {scope, pair, now})
        pair
    end
  end

  @doc "What a value goes back to on Reset: the built-in default for the server, else what the server or the job's own file says."
  def base(:server), do: defaults()
  def base({:machine, _}), do: all(:server)
  def base({:job, id}), do: Map.merge(all(:server), from_job(id))

  defp own_now(:server), do: Map.merge(from_alerts_changed(), stored(:server))
  defp own_now(scope), do: stored(scope)

  defp stored(scope), do: Map.take(Setting.get(key(scope)), keys())

  defp key(:server), do: "values"
  defp key({:machine, id}), do: "values:machine:" <> id
  defp key({:job, id}), do: "values:job:" <> id

  defp alerts_values(config) do
    Enum.reduce(@alerts, %{}, fn {_, {on, limit}}, acc ->
      case Float.parse(config[limit] || "") do
        {n, _} -> Map.merge(acc, %{on => true, limit => if(n == trunc(n), do: trunc(n), else: n)})
        :error -> Map.put(acc, on, false)
      end
    end)
  end

  defp from_alerts_changed do
    alerts_values(Dokkit.Alerts.config())
    |> Enum.reject(fn {k, v} -> v == default(k) end)
    |> Map.new()
  end

  @doc "Every job's own values in one read, as %{service id => values}."
  def job_overrides do
    import Ecto.Query

    for %{key: "values:job:" <> id, value: v} <-
          Repo.all(from s in Setting, where: like(s.key, "values:job:%")),
        into: %{},
        do: {id, Map.take(v, keys())}
  end

  @doc "A job's values from its check and its own values, with no read of its own."
  def for_job(%{config: config}, own),
    do: all(:server) |> Map.merge(from_config(config)) |> Map.merge(own)

  defp from_job(service_id) do
    case job_check(service_id) do
      %{config: config} -> from_config(config)
      nil -> %{}
    end
  end

  defp from_config(config) do
    grace = config["grace"] && Dokkit.Watch.seconds(config["grace"], nil)
    max = config["max_runtime"] && Dokkit.Watch.seconds(config["max_runtime"], nil)

    # A max_runtime that cannot be read still turns the limit on, at the default length.
    %{}
    |> put_if(grace, "job_grace_minutes", grace && div(grace, 60))
    |> put_if(config["max_runtime"], "job_max_on", true)
    |> put_if(max, "job_max_minutes", max && max(1, div(max, 60)))
  end

  defp put_if(map, nil, _, _), do: map
  defp put_if(map, _, key, value), do: Map.put(map, key, value)

  defp job_check(service_id) do
    import Ecto.Query

    case Ecto.UUID.cast(service_id) do
      {:ok, id} ->
        Repo.one(from c in Dokkit.Check, where: c.service_id == ^id and c.type == :job, limit: 1)

      :error ->
        nil
    end
  end

  @doc """
  Saves values for a scope. A value is a number, true or false, or text for a list of choices;
  nil or an empty text puts it back to its default. Keys not given stay as they were.
  `{:ok, view}` or `{:error, text}`.
  """
  def save(scope, params) when is_map(params) do
    forget()
    allowed = for r <- @rows, shown?(r, scope), f <- fields(r), into: MapSet.new(), do: elem(f, 0)
    given = Map.take(params, MapSet.to_list(allowed))
    unknown = Map.keys(params) -- MapSet.to_list(allowed)

    with :ok <- known(unknown, scope),
         {:ok, parsed} <- parse_all(given),
         base = base(scope),
         parsed = Map.new(parsed, fn {k, v} -> {k, if(v == base[k], do: :reset, else: v)} end),
         :ok <- together(Map.merge(all(scope), Map.new(parsed, &settled(&1, base))), parsed) do
      write(scope, parsed)
      forget()
      {:ok, view(scope)}
    end
  end

  def save(_, _), do: {:error, "Send the values as an object."}

  defp settled({k, :reset}, base), do: {k, base[k]}
  defp settled(kv, _), do: kv

  @doc "Puts every value of one row back to its default."
  def reset(scope, row_id) do
    case Enum.find(@rows, &(&1.id == row_id and shown?(&1, scope))) do
      nil -> {:error, "No such setting."}
      r -> save(scope, Map.new(fields(r), &{elem(&1, 0), nil}))
    end
  end

  defp known([], _), do: :ok

  defp known(keys, scope) do
    where = if scope == :server, do: "", else: " for a #{elem(scope, 0)}"

    {:error,
     "#{Enum.join(Enum.sort(keys), ", ")} #{if length(keys) == 1, do: "is not a setting", else: "are not settings"}#{where}."}
  end

  defp parse_all(given) do
    Enum.reduce_while(given, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case parse(elem(@fields[k], 0), v) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, k, value)}}
        {:error, why} -> {:halt, {:error, why}}
      end
    end)
  end

  defp parse(_, v) when v in [nil, ""], do: {:ok, :reset}

  defp parse({key, default, :text}, v) when is_binary(v) do
    case choices(key, v) do
      {:ok, _} -> {:ok, v |> String.split(",") |> Enum.map_join(", ", &String.trim/1)}
      :error -> {:error, "#{key} is lengths with commas between, such as #{default}."}
    end
  end

  defp parse({key, _, :text}, _), do: {:error, "#{key} is text."}

  defp parse({key, default}, v) when is_boolean(default) do
    case v do
      b when is_boolean(b) -> {:ok, b}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, "#{key} is true or false."}
    end
  end

  defp parse({key, _, min, max}, v) do
    n =
      case v do
        n when is_integer(n) -> n
        t when is_binary(t) -> with {n, ""} <- Integer.parse(String.trim(t)), do: n
        _ -> nil
      end

    if is_integer(n) and n in min..max,
      do: {:ok, n},
      else: {:error, "#{key} is a whole number from #{min} to #{max}."}
  end

  # Each pair is checked only when one of its values is being saved, so a stored value that was
  # fine before never blocks an unrelated save.
  defp pairs do
    [
      {~w(enrol_hours enrol_max_hours), "enrol_hours is at most enrol_max_hours.",
       &(&1["enrol_hours"] <= &1["enrol_max_hours"])},
      {~w(forecast_days forecast_clear_days),
       "forecast_clear_days is at least forecast_days, or a warning would flap.",
       &(&1["forecast_clear_days"] >= &1["forecast_days"])},
      {~w(forecast_min_days forecast_window_days),
       "forecast_min_days is at most forecast_window_days.",
       &(&1["forecast_min_days"] <= &1["forecast_window_days"])},
      {~w(disk_limit disk_down), "disk_down is at or above disk_limit.",
       &(&1["disk_down"] >= &1["disk_limit"])},
      {~w(memory_limit memory_down), "memory_down is at or above memory_limit.",
       &(&1["memory_down"] >= &1["memory_limit"])},
      {~w(silent_minutes report_seconds),
       "silent_minutes is at least two reports and a minute: silent_minutes * 60 >= 2 * report_seconds + 60.",
       &(&1["silent_minutes"] * 60 >= 2 * &1["report_seconds"] + 60)},
      {~w(update_run_minutes updater_minutes),
       "update_run_minutes is at least updater_minutes and 5 more, so an update still running is not called failed.",
       &(&1["update_run_minutes"] >= &1["updater_minutes"] + 5)},
      {~w(quiet_choices quiet_max_hours), "quiet_choices are at most quiet_max_hours.",
       &quiet_fits?/1}
    ]
  end

  defp together(v, parsed) do
    saving = Map.keys(parsed)

    Enum.find_value(pairs(), :ok, fn {keys, why, ok?} ->
      if Enum.any?(keys, &(&1 in saving)) and not ok?.(v), do: {:error, why}
    end)
  end

  defp quiet_fits?(v) do
    case choices("quiet_choices", v["quiet_choices"]) do
      {:ok, list} -> Enum.all?(list, &(elem(&1, 0) <= v["quiet_max_hours"] * 3600))
      :error -> true
    end
  end

  defp write(scope, parsed) do
    {alerts, rest} =
      if scope == :server do
        Map.split(parsed, Enum.flat_map(@alerts, fn {_, {on, limit}} -> [on, limit] end))
      else
        {%{}, parsed}
      end

    if alerts != %{}, do: write_alerts(alerts)

    if rest != %{} do
      old = stored(scope)

      new =
        Enum.reduce(rest, old, fn
          {k, :reset}, acc -> Map.delete(acc, k)
          {k, v}, acc -> Map.put(acc, k, v)
        end)

      Setting.put(key(scope), new)
    end
  end

  defp write_alerts(given) do
    now = alerts_values(Dokkit.Alerts.config())

    changes =
      for {_, {on, limit}} <- @alerts,
          Map.has_key?(given, on) or Map.has_key?(given, limit),
          into: %{} do
        on? = pick(given[on], now[on], default(on))
        n = pick(given[limit], now[limit], default(limit))
        {limit, if(on?, do: to_string(n), else: "")}
      end

    Dokkit.Alerts.save(changes)
  end

  defp pick(:reset, _, default), do: default
  defp pick(nil, nil, default), do: default
  defp pick(nil, now, _), do: now
  defp pick(given, _, _), do: given

  @units %{"m" => 60, "h" => 3600, "d" => 86_400, "w" => 604_800}

  @doc "A list of choices as `{seconds, words}`, from text such as `1h, 4h, 1d`."
  def choices(key, text \\ nil) do
    text = text || get(key)

    list =
      text
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&Regex.run(~r/^(\d+)\s*([mhdw])$/, &1))

    if list != [] and length(list) <= 12 and Enum.all?(list, & &1) and
         Enum.all?(list, fn [_, n, _] -> String.to_integer(n) > 0 end),
       do:
         {:ok,
          list
          |> Enum.map(fn [_, n, u] ->
            {String.to_integer(n) * @units[u], words(String.to_integer(n), u)}
          end)
          |> Enum.uniq_by(&elem(&1, 0))
          |> Enum.sort()},
       else: :error
  end

  defp words(n, u) do
    unit = %{"m" => "minute", "h" => "hour", "d" => "day", "w" => "week"}[u]
    "#{n} #{unit}#{if n == 1, do: "", else: "s"}"
  end

  @doc "The values of a scope as the API shows them: each value now, what Reset gives, and which were changed here."
  def view(scope) do
    rows = for r <- @rows, shown?(r, scope), f <- fields(r), do: elem(f, 0)
    base = Map.take(base(scope), rows)
    own = Map.take(own(scope), rows)

    %{
      "values" => Map.merge(base, own),
      "defaults" => base,
      "changed" =>
        own |> Enum.reject(fn {k, v} -> base[k] == v end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    }
  end

  @doc "How a row's value reads, as its Default line says it."
  def say(r, values) do
    words =
      r.words
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {w, i} ->
        case Enum.at(r.fields, i) do
          nil -> w
          f -> String.trim("#{w} #{values[elem(f, 0)]}")
        end
      end)
      |> String.replace(" %", "%")
      |> String.replace(" ,", ",")
      |> String.trim()

    case r[:toggle] do
      nil ->
        words

      {on, _} ->
        cond do
          not values[on] -> "Off"
          words == "" -> "On"
          true -> "On, " <> lower(words)
        end
    end
  end

  defp lower(<<c::utf8, rest::binary>>), do: String.downcase(<<c::utf8>>) <> rest
  defp lower(""), do: ""

  @doc "What the program on a machine is told with its checks."
  def for_program(machine_id) do
    v = all({:machine, machine_id})

    %{
      "report_seconds" => v["report_seconds"],
      "scan_first_seconds" => v["scan_first_minutes"] * 60,
      "scan_every_seconds" => v["scan_every_hours"] * 3600,
      "check_every_seconds" => v["check_every_seconds"],
      "check_timeout_seconds" => v["check_timeout_seconds"],
      "expiry_days" => v["expiry_days"],
      "restart_gap_seconds" => v["restart_gap_minutes"] * 60
    }
  end
end
