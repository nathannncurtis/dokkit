defmodule Dokkit.Watch do
  @moduledoc "Once a minute, finds jobs that did not run when they should have, or have run too long."
  use GenServer
  import Ecto.Query
  require Logger
  alias Dokkit.{Check, Issues, JobRun, Repo}

  @every :timer.minutes(1)
  @units %{"s" => 1, "m" => 60, "h" => 3600, "d" => 86_400}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    Process.send_after(self(), :sweep, @every)
    {:ok, DateTime.utc_now()}
  end

  # After a server outage, machines have had no chance to report yet.
  @settle_seconds 180

  def settled?(booted, now), do: DateTime.diff(now, booted) >= @settle_seconds

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
          fn -> prune(now) end,
          fn -> Dokkit.Digest.tick(now, Dokkit.Alerts.config()) end,
          fn -> Dokkit.Self.tick(now, Dokkit.Alerts.config(), booted) end,
          fn -> if archive && now.minute == 0, do: Dokkit.Logs.archive(archive) end,
          fn -> Issues.changed() end,
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
  @keep_hosts_days 30

  @doc "Drops numbers past their keep time, spent batch ids, and app hosts never seen again."
  def prune(now) do
    Dokkit.Numbers.prune(now)

    Repo.delete_all(
      from b in Dokkit.Batch,
        where: b.inserted_at < ^DateTime.add(now, -@keep_batches_hours * 3600)
    )

    Repo.delete_all(
      from m in Dokkit.Machine,
        as: :machine,
        where:
          m.kind == :seen and m.last_seen_at < ^DateTime.add(now, -@keep_hosts_days * 86_400) and
            not exists(from s in Dokkit.Service, where: s.machine_id == parent_as(:machine).id)
    )
  end

  @doc "Returns how many jobs and beats it flagged."
  def sweep(now \\ DateTime.utc_now(), booted \\ nil) do
    Repo.all(
      from c in Check, where: c.type in [:job, :beat] and c.state != :down, preload: :service
    )
    |> Enum.count(fn check ->
      case safe_verdict(check, now, booted) do
        nil -> false
        {title, note} -> Issues.record(check, :down, at: now, title: title, note: note)
      end
    end)
  end

  # One check with a schedule that cannot be read must not stop the others.
  defp safe_verdict(check, now, booted) do
    verdict(check, now, booted)
  rescue
    e ->
      Logger.error("Watch could not judge #{check.id}: " <> Exception.message(e))
      nil
  end

  # Two beats late and a minute more, so one slow loop is not an alarm.
  defp verdict(
         %Check{type: :beat, checked_at: %DateTime{} = last, config: config} = check,
         now,
         booted
       ) do
    every = config["every_seconds"] || 60
    quiet = DateTime.diff(now, later(last, booted))

    if quiet > every * 2 + 60,
      do:
        {"#{check.service.name}: #{check.name} went quiet",
         "No beat for #{div(quiet, 60)} min. One was expected every #{every} s."}
  end

  defp verdict(%Check{type: :beat}, _, _), do: nil
  defp verdict(check, now, booted), do: missed(check, now, booted) || overran(check, now)

  # Time the server was down is not time the app was quiet.
  defp later(time, nil), do: time
  defp later(time, booted), do: Enum.max([time, booted], DateTime)

  # Schedules are read as UTC until jobs carry a timezone.
  defp missed(%Check{config: %{"schedule" => cron} = config} = check, now, booted)
       when is_binary(cron) do
    with {:ok, expr} <- Crontab.CronExpression.Parser.parse(cron),
         {:ok, due} <- Crontab.Scheduler.get_previous_run_date(expr, DateTime.to_naive(now)),
         {:ok, before} <-
           Crontab.Scheduler.get_previous_run_date(expr, NaiveDateTime.add(due, -1)),
         early = min(60, div(NaiveDateTime.diff(due, before), 2)),
         due = DateTime.from_naive!(due, "Etc/UTC"),
         true <- DateTime.compare(check.inserted_at, due) == :lt,
         true <- is_nil(booted) or DateTime.compare(booted, due) == :lt,
         true <- DateTime.diff(now, due) > seconds(config["grace"], 1800),
         false <-
           Repo.exists?(
             from r in JobRun,
               where:
                 r.check_id == ^check.id and
                   coalesce(r.started_at, r.finished_at) >= ^DateTime.add(due, -early)
           ) do
      {"#{Dokkit.Intake.label(check.service, check.name)} did not run",
       "Expected at #{Calendar.strftime(due, "%H:%M")} UTC"}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp missed(_, _, _), do: nil

  defp overran(%Check{config: %{"max_runtime" => max}} = check, now) do
    limit = DateTime.add(now, -seconds(max, 3600))

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

  defp overran(_, _), do: nil

  def seconds(text, default) do
    case is_binary(text) && Regex.run(~r/^(\d+)([smhd])$/, text) do
      [_, n, unit] -> String.to_integer(n) * @units[unit]
      _ -> default
    end
  end
end
