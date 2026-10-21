defmodule Dokkit.Watch do
  @moduledoc "Once a minute, finds jobs that did not run when they should have, or have run too long."
  use GenServer
  import Ecto.Query
  require Logger
  alias Dokkit.{Check, Issues, JobRun, Repo, Values}
  alias DokkitWeb.Show

  @every :timer.minutes(1)
  @units %{"s" => 1, "m" => 60, "h" => 3600, "d" => 86_400}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    Process.send_after(self(), :sweep, @every)

    {:ok,
     DateTime.add(DateTime.utc_now(), -elem(:erlang.statistics(:wall_clock), 0), :millisecond)}
  end

  # After a server outage, machines have had no chance to report yet.
  def settled?(booted, now),
    do: DateTime.diff(now, booted) >= Values.get("warmup_minutes") * 60

  def handle_info(:sweep, booted) do
    Process.send_after(self(), :sweep, @every)
    now = DateTime.utc_now()
    archive = Application.get_env(:dokkit, :archive)

    steps =
      if(settled?(booted, now),
        do: [fn -> Issues.machines_sweep(now) end, fn -> sweep(now, booted) end],
        else: []
      ) ++
        [
          fn -> if Dokkit.Alerts.release(now) > 0, do: Dokkit.Alerts.flush() end,
          fn -> if Dokkit.Alerts.remind(now) > 0, do: Dokkit.Alerts.flush() end,
          fn -> Dokkit.Errors.calm() end,
          fn -> Dokkit.Alerts.settle(now) end,
          fn -> Dokkit.Alerts.resolve_tests(now) end,
          fn -> Dokkit.Work.expire() end,
          fn -> if now.minute in [0, 30], do: Dokkit.Numbers.forecast(now) end,
          fn -> prune(now) end,
          fn -> Dokkit.Digest.tick(now, Dokkit.Alerts.config()) end,
          fn -> Dokkit.Self.tick(now, Dokkit.Alerts.config(), booted) end,
          fn -> Task.start(fn -> Dokkit.Acme.tick(now) end) end,
          fn -> if now.minute == 0, do: Task.start(fn -> Dokkit.Logs.archive(archive) end) end,
          fn -> Issues.changed() end,
          fn -> Dokkit.Phones.Sender.tick() end,
          fn ->
            today = Date.utc_today()
            Enum.each([today, Date.shift(today, month: 1)], &Dokkit.Logs.ensure_partition/1)
          end
        ]

    Enum.each(steps, &step/1)
    {:noreply, booted}
  end

  defp step(fun) do
    fun.()
  rescue
    e -> Logger.error("Watch step failed: " <> Exception.message(e))
  catch
    :exit, reason -> Logger.error("Watch step failed: " <> inspect(reason))
  end

  @keep_batches_hours 24

  @doc "Drops numbers past their keep time, spent batch ids, app hosts never seen again, and old job and work runs."
  def prune(now) do
    Dokkit.Numbers.prune(now)
    Dokkit.Slots.prune(now)
    Dokkit.Processes.prune(now)

    Repo.delete_all(
      from b in Dokkit.Batch,
        where: b.inserted_at < ^DateTime.add(now, -@keep_batches_hours * 3600)
    )

    Repo.delete_all(
      from m in Dokkit.Machine,
        as: :machine,
        where:
          m.kind == :seen and
            m.last_seen_at < ^DateTime.add(now, -Values.get("hosts_days") * 86_400) and
            not exists(from s in Dokkit.Service, where: s.machine_id == parent_as(:machine).id)
    )

    runs_before = DateTime.add(now, -Values.get("job_keep_days") * 86_400)

    # Each check keeps its newest run and newest good run: the Jobs page and "did not run" read them.
    keep_jobs =
      from r in JobRun,
        distinct: r.check_id,
        order_by: [r.check_id, desc: coalesce(r.started_at, r.finished_at), desc: r.id],
        select: r.id

    keep_good =
      from r in JobRun,
        where: r.result == :ok and not is_nil(r.finished_at),
        distinct: r.check_id,
        order_by: [r.check_id, desc: r.finished_at],
        select: r.id

    own = own_keep()

    for {cutoff, ids} <- [
          {runs_before, nil}
          | Enum.map(own, fn {id, days} -> {DateTime.add(now, -days * 86_400), [id]} end)
        ] do
      Repo.delete_all(
        from r in JobRun,
          join: c in assoc(r, :check),
          where: ^runs_of(ids, Map.keys(own)),
          where:
            coalesce(r.finished_at, r.started_at) < ^cutoff and
              r.id not in subquery(keep_jobs) and r.id not in subquery(keep_good)
      )
    end

    keep_work =
      from r in Dokkit.WorkRun,
        distinct: [r.machine_id, r.name],
        order_by: [r.machine_id, r.name, desc: r.inserted_at],
        select: r.id

    Repo.delete_all(
      from r in Dokkit.WorkRun,
        where:
          r.state not in [:queued, :running] and r.inserted_at < ^runs_before and
            r.id not in subquery(keep_work)
    )
  end

  # The jobs (by service id) that keep their runs for their own number of days.
  defp own_keep do
    for {id, %{"job_keep_days" => days}} <- Values.job_overrides(), into: %{}, do: {id, days}
  end

  defp runs_of(nil, []), do: dynamic(true)
  defp runs_of(nil, own), do: dynamic([_, c], c.service_id not in ^own)
  defp runs_of(ids, _), do: dynamic([_, c], c.service_id in ^ids)

  @doc "Returns how many jobs and beats it flagged."
  def sweep(now \\ DateTime.utc_now(), booted \\ nil) do
    quiet = MapSet.new(Dokkit.Quiet.active(now), & &1.machine_id)
    over = Dokkit.Quiet.overs()
    jobs = Values.job_overrides()

    Repo.all(
      from c in Check, where: c.type in [:job, :beat] and c.state != :down, preload: :service
    )
    |> Enum.reject(&(&1.service.machine_id in quiet))
    |> Enum.count(fn check ->
      since =
        [booted, over[check.service.machine_id]]
        |> Enum.reject(&is_nil/1)
        |> Enum.max(DateTime, fn -> nil end)

      case safe_verdict(check, now, since, jobs) do
        nil -> false
        {title, note} -> Issues.record(check, :down, at: now, title: title, note: note)
      end
    end)
  end

  # One check with a schedule that cannot be read must not stop the others.
  defp safe_verdict(check, now, booted, jobs) do
    verdict(check, now, booted, jobs)
  rescue
    e ->
      Logger.error("Watch could not judge #{check.id}: " <> Exception.message(e))
      nil
  end

  # Two beats late and a minute more, so one slow loop is not an alarm.
  defp verdict(%Check{config: %{"waiting" => true}}, _, _, _), do: nil

  defp verdict(
         %Check{type: :beat, checked_at: %DateTime{} = last, config: config} = check,
         now,
         booted,
         _
       ) do
    every = config["every_seconds"] || 60
    quiet = DateTime.diff(now, later(last, booted))
    v = Values.all()

    if quiet > every * v["beat_misses"] + v["beat_slack_seconds"],
      do:
        {"#{check.service.name}: #{check.name} went quiet",
         "No beat for #{div(quiet, 60)} min. One was expected every #{every} s."}
  end

  defp verdict(%Check{type: :beat}, _, _, _), do: nil

  defp verdict(check, now, booted, jobs) do
    own = Map.get(jobs, check.service_id, %{})
    v = check |> Values.for_job(own) |> Map.put(:own, own)
    (v["job_missed"] && missed(check, now, booted, v)) || overran(check, now, v)
  end

  # Time the server was down is not time the app was quiet.
  defp later(time, nil), do: time
  defp later(time, booted), do: Enum.max([time, booted], DateTime)

  # Schedules are read as UTC until jobs carry a timezone.
  defp missed(%Check{config: %{"schedule" => cron}} = check, now, booted, v)
       when is_binary(cron) do
    with {:ok, expr} <- Crontab.CronExpression.Parser.parse(cron),
         {:ok, due} <- Crontab.Scheduler.get_previous_run_date(expr, DateTime.to_naive(now)),
         {:ok, before} <-
           Crontab.Scheduler.get_previous_run_date(expr, NaiveDateTime.add(due, -1)),
         early = min(60, div(NaiveDateTime.diff(due, before), 2)),
         due = DateTime.from_naive!(due, "Etc/UTC"),
         true <- DateTime.compare(check.inserted_at, due) == :lt,
         true <- is_nil(booted) or DateTime.compare(booted, due) == :lt,
         true <- DateTime.diff(now, due) > grace(check, v),
         false <-
           Repo.exists?(
             from r in JobRun,
               where:
                 r.check_id == ^check.id and
                   coalesce(r.started_at, r.finished_at) >= ^DateTime.add(due, -early)
           ) do
      {"#{Dokkit.Intake.label(check.service, check.name)} did not run",
       "Expected at #{Calendar.strftime(due, "%H:%M")} UTC." <> last_good(check)}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp missed(_, _, _, _), do: nil

  # In seconds, so a grace of 90s in a file is not rounded to minutes.
  defp grace(check, v) do
    if check.config["grace"] && not Map.has_key?(v.own, "job_grace_minutes"),
      do: seconds(check.config["grace"], v["job_grace_minutes"] * 60),
      else: v["job_grace_minutes"] * 60
  end

  defp last_good(check) do
    run =
      Repo.one(
        from r in JobRun,
          where: r.check_id == ^check.id and r.result == :ok and not is_nil(r.finished_at),
          order_by: [desc: r.finished_at],
          limit: 1
      )

    case run && took_ms(run) do
      nil -> if run, do: " Its last good run was #{Show.at(run.finished_at)} UTC.", else: ""
      ms -> " Its last good run was #{Show.at(run.finished_at)} UTC and took #{Show.took(ms)}."
    end
  end

  defp took_ms(%JobRun{duration_ms: ms}) when is_integer(ms), do: ms

  defp took_ms(%JobRun{started_at: %DateTime{} = from, finished_at: %DateTime{} = to}),
    do: DateTime.diff(to, from, :millisecond)

  defp took_ms(_), do: nil

  @doc "The title and note for a finished run that took longer than the job's max_runtime, else nil."
  def ran_long(%Check{} = check, %JobRun{} = run, label) do
    v = Map.put(Values.all({:job, check.service_id}), :own, Values.own({:job, check.service_id}))

    case max_runtime(check, v) do
      nil -> nil
      {max, seconds} -> ran_long(check, run, label, max, seconds * 1000)
    end
  end

  defp ran_long(check, run, label, max, limit) do
    ms = took_ms(run)

    if ms && ms > limit do
      week = DateTime.add(run.finished_at || DateTime.utc_now(), -7 * 86_400)

      times =
        Repo.all(
          from r in JobRun,
            where: r.check_id == ^check.id and r.result == :ok and r.finished_at > ^week
        )
        |> Enum.count(&((took_ms(&1) || 0) > limit))

      {"#{label} ran long",
       "It took #{Show.took(ms)}. The limit is #{max}." <>
         if(times > 1, do: " That is #{times} times in the last 7 days.", else: "")}
    end
  end

  # The limit as it is written, and in seconds: the job's own setting, else its max_runtime, else the default when switched on.
  defp max_runtime(check, v) do
    if v["job_max_on"] do
      text = check.config["max_runtime"]

      if text && not Map.has_key?(v.own, "job_max_minutes"),
        do: {text, seconds(text, v["job_max_minutes"] * 60)},
        else: {"#{v["job_max_minutes"]}m", v["job_max_minutes"] * 60}
    end
  end

  defp overran(check, now, v) do
    case max_runtime(check, v) do
      nil -> nil
      {max, seconds} -> overran(check, now, max, seconds)
    end
  end

  defp overran(check, now, max, seconds) do
    limit = DateTime.add(now, -seconds)

    newest =
      Repo.one(
        from r in JobRun,
          where: r.check_id == ^check.id,
          order_by: [desc: coalesce(r.started_at, r.finished_at)],
          limit: 1
      )

    if match?(%JobRun{result: :running, started_at: %DateTime{}}, newest) and
         DateTime.compare(newest.started_at, limit) == :lt,
       do:
         {"#{Dokkit.Intake.label(check.service, check.name)} has run too long",
          "Longer than #{max}"}
  end

  def seconds(text, default) do
    case is_binary(text) && Regex.run(~r/^(\d+)([smhd])$/, text) do
      [_, n, unit] -> String.to_integer(n) * @units[unit]
      _ -> default
    end
  end
end
