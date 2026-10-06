defmodule Dokkit.Watch do
  @moduledoc "Once a minute, finds jobs that did not run when they should have, or have run too long."
  use GenServer
  import Ecto.Query
  alias Dokkit.{Check, Issues, JobRun, Repo}

  @every :timer.minutes(1)
  @settle 300
  @units %{"s" => 1, "m" => 60, "h" => 3600, "d" => 86_400}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    Process.send_after(self(), :sweep, @every)

    {:ok,
     DateTime.add(DateTime.utc_now(), -elem(:erlang.statistics(:wall_clock), 0), :millisecond)}
  end

  def handle_info(:sweep, started) do
    Process.send_after(self(), :sweep, @every)

    sweep_quiet(started)

    Dokkit.Numbers.prune(DateTime.utc_now())
    Dokkit.Digest.tick(DateTime.utc_now(), Dokkit.Alerts.config())
    Dokkit.Self.tick(DateTime.utc_now(), Dokkit.Alerts.config())
    archive = Application.get_env(:dokkit, :archive)
    if archive && DateTime.utc_now().minute == 0, do: Dokkit.Logs.archive(archive)
    Issues.changed()
    today = Date.utc_today()
    Enum.each([today, Date.shift(today, month: 1)], &Dokkit.Logs.ensure_partition/1)
    {:noreply, started}
  end

  @doc "Sweeps jobs, beats and machines once the VM has been up long enough for machines to report."
  def sweep_quiet(started, now \\ DateTime.utc_now()) do
    if settled?(started, now) do
      sweep(now)
      Issues.machines_sweep(now)
    else
      0
    end
  end

  @doc "A machine that was quiet while Dokkit was down is given time to report before it is flagged."
  def settled?(started, now \\ DateTime.utc_now()), do: DateTime.diff(now, started) > @settle

  @doc "Returns how many jobs and beats it flagged."
  def sweep(now \\ DateTime.utc_now()) do
    Repo.all(
      from c in Check, where: c.type in [:job, :beat] and c.state != :down, preload: :service
    )
    |> Enum.count(fn check ->
      case verdict(check, now) do
        nil -> false
        {title, note} -> Issues.record(check, :down, at: now, title: title, note: note)
      end
    end)
  end

  # Two beats late and a minute more, so one slow loop is not an alarm.
  defp verdict(%Check{type: :beat, checked_at: %DateTime{} = last, config: config} = check, now) do
    every = config["every_seconds"] || 60
    quiet = DateTime.diff(now, last)

    if quiet > every * 2 + 60,
      do:
        {"#{check.service.name}: #{check.name} went quiet",
         "No beat for #{div(quiet, 60)} min. One was expected every #{every} s."}
  end

  defp verdict(%Check{type: :beat}, _), do: nil
  defp verdict(check, now), do: missed(check, now) || overran(check, now)

  # Schedules are read as UTC until jobs carry a timezone.
  defp missed(%Check{config: %{"schedule" => cron} = config} = check, now) do
    with {:ok, expr} <- Crontab.CronExpression.Parser.parse(cron),
         {:ok, due} <- Crontab.Scheduler.get_previous_run_date(expr, DateTime.to_naive(now)),
         due = DateTime.from_naive!(due, "Etc/UTC"),
         true <- DateTime.compare(check.inserted_at, due) == :lt,
         true <- DateTime.diff(now, due) > seconds(config["grace"], 1800),
         false <-
           Repo.exists?(
             from r in JobRun,
               where: r.check_id == ^check.id and coalesce(r.started_at, r.finished_at) >= ^due
           ) do
      {"#{Dokkit.Intake.label(check.service, check.name)} did not run",
       "Expected at #{Calendar.strftime(due, "%H:%M")} UTC"}
    else
      _ -> nil
    end
  end

  defp missed(_, _), do: nil

  defp overran(%Check{config: %{"max_runtime" => max}} = check, now) do
    limit = DateTime.add(now, -seconds(max, 3600))

    if Repo.exists?(
         from r in JobRun,
           where: r.check_id == ^check.id and r.result == :running and r.started_at < ^limit
       ),
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
