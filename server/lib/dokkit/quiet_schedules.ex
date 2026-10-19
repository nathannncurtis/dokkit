defmodule Dokkit.QuietSchedules do
  @moduledoc "Scheduled planned downtime: windows a machine gets by itself, once or repeating."
  import Ecto.Query
  alias Dokkit.{Alerts, Quiet, QuietSchedule, Repo}

  @repeats ~w(once daily weekly)
  @weekdays ~w(Mon Tue Wed Thu Fri Sat Sun)
  @time ~r/^([01]\d|2[0-3]):[0-5]\d$/

  @doc "A machine's schedules, as the API shows them."
  def list(machine_id, now \\ DateTime.utc_now()) do
    config = Alerts.config()
    for s <- all(machine_id), do: view(s, now, config)
  end

  def all(machine_id) do
    case Ecto.UUID.cast(machine_id) do
      {:ok, id} ->
        Repo.all(from s in QuietSchedule, where: s.machine_id == ^id, order_by: s.inserted_at)

      _ ->
        []
    end
  end

  def view(%QuietSchedule{} = s, now, config) do
    %{
      id: s.id,
      repeat: s.repeat,
      at: s.at,
      time: s.time,
      days: s.days,
      for_seconds: s.seconds,
      reason: s.reason,
      by: s.by,
      next: next(s, now, zone(config))
    }
  end

  @doc "Adds a schedule. `at` is an RFC 3339 time; `time` is the time of day in the night time zone."
  def add(machine_id, %{} = params, by, now \\ DateTime.utc_now()) do
    zone = zone(Alerts.config())

    with {:ok, seconds} <- seconds(params["for"]),
         true <- Quiet.machine_exists?(machine_id),
         {:ok, fields} <- when_fields(params, zone, now) do
      {:ok,
       Repo.insert!(
         struct(
           QuietSchedule,
           Map.merge(fields, %{
             machine_id: machine_id,
             seconds: seconds,
             reason: Quiet.reason(params["reason"]),
             by: by
           })
         )
       )}
    else
      false -> {:error, "not_found", "No such thing."}
      error -> error
    end
  end

  def remove(machine_id, id) do
    with {:ok, machine} <- Ecto.UUID.cast(machine_id),
         {:ok, id} <- Ecto.UUID.cast(id),
         {1, _} <-
           Repo.delete_all(
             from s in QuietSchedule, where: s.id == ^id and s.machine_id == ^machine
           ) do
      {:ok, nil}
    else
      _ -> {:error, "not_found", "No such thing."}
    end
  end

  defp seconds(text) do
    case Quiet.parse(text) do
      {:ok, n} when n > 0 ->
        {:ok, n}

      _ ->
        {:error, "bad_duration",
         "for is a duration up to #{div(Quiet.most(), 3600)}h, such as 30m."}
    end
  end

  defp bad(text), do: {:error, "bad_schedule", text}

  defp when_fields(%{"repeat" => "once", "at" => at}, _zone, now) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _} ->
        at = %{at | microsecond: {elem(at.microsecond, 0), 6}}

        if DateTime.compare(at, now) == :gt,
          do: {:ok, %{repeat: "once", at: at}},
          else: bad("at must be a time in the future.")

      _ ->
        bad("at is a time in RFC 3339, such as 2026-10-14T21:00:00-07:00.")
    end
  end

  defp when_fields(%{"repeat" => "once"}, _, _), do: bad("at is the date and time to start.")

  defp when_fields(%{"repeat" => repeat} = params, _, _) when repeat in ~w(daily weekly) do
    time = params["time"]

    cond do
      not (is_binary(time) and Regex.match?(@time, time)) ->
        bad("time is the time of day, such as 02:00.")

      repeat == "daily" ->
        {:ok, %{repeat: repeat, time: time, days: [1, 2, 3, 4, 5, 6, 7]}}

      true ->
        case days(params["days"]) do
          [] -> bad("days are the weekdays, 1 for Monday to 7 for Sunday.")
          days -> {:ok, %{repeat: repeat, time: time, days: days}}
        end
    end
  end

  defp when_fields(_, _, _), do: bad("repeat is once, daily or weekly.")

  defp days(list) when is_list(list) do
    numbers = for d <- list, n = day(d), do: n
    if length(numbers) == length(list), do: numbers |> Enum.uniq() |> Enum.sort(), else: []
  end

  defp days(_), do: []

  defp day(n) when n in 1..7, do: n

  defp day(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n in 1..7 -> n
      _ -> nil
    end
  end

  defp day(_), do: nil

  @doc "The time zone the schedules are kept in: the night time zone, or UTC when none is set."
  def zone(config), do: if(Alerts.zone_set?(config), do: config["night_zone"], else: "Etc/UTC")

  @doc "Its short name now, such as PDT, or UTC."
  def zone_label(config, now \\ DateTime.utc_now()) do
    case DateTime.shift_zone(now, zone(config)) do
      {:ok, %{zone_abbr: "UTC"}} -> "UTC"
      {:ok, local} -> local.zone_abbr
      _ -> "UTC"
    end
  end

  @doc "A time typed in the zone, as `2026-10-14T21:00`, as an RFC 3339 time. Nil when it is not a time."
  def local_to_utc(text, config) when is_binary(text) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(text <> ":00"),
         %DateTime{} = at <- instant(naive, zone(config)) do
      DateTime.to_iso8601(at)
    else
      _ -> nil
    end
  end

  def local_to_utc(_, _), do: nil

  defp instant(%NaiveDateTime{} = naive, zone) do
    case DateTime.from_naive(naive, zone) do
      {:ok, local} -> DateTime.shift_zone!(local, "Etc/UTC")
      {:ambiguous, first, _} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _, after_gap} -> DateTime.shift_zone!(after_gap, "Etc/UTC")
      _ -> nil
    end
  end

  defp instant(date, time, zone) do
    {:ok, naive} = NaiveDateTime.new(date, Time.from_iso8601!(time <> ":00"))
    instant(naive, zone)
  end

  defp today(now, zone), do: now |> DateTime.shift_zone!(zone) |> DateTime.to_date()

  @doc "When it next starts, or nil for a one-off that has passed."
  def next(%QuietSchedule{repeat: "once", at: at}, now, _zone),
    do: if(DateTime.compare(at, now) == :gt, do: at)

  def next(%QuietSchedule{} = s, now, zone) do
    today = today(now, zone)

    Enum.find_value(0..7, fn n ->
      date = Date.add(today, n)
      start = Date.day_of_week(date) in s.days && instant(date, s.time, zone)
      if start && DateTime.compare(start, now) == :gt, do: start
    end)
  end

  @doc "A machine's schedules as the page shows them: a line in plain words and the next start."
  def lines(machine_id, now, config) do
    for s <- all(machine_id) do
      next = next(s, now, zone(config))
      %{id: s.id, text: say(s, config), next: next && local_text(next, config)}
    end
  end

  defp local_text(at, config) do
    local = DateTime.shift_zone!(at, zone(config))
    Calendar.strftime(local, "%b %-d %H:%M ") <> label(local)
  end

  @doc "One line in plain words."
  def say(%QuietSchedule{} = s, config) do
    zone = zone(config)
    span = length_text(s.seconds)
    why = if s.reason, do: ": " <> s.reason, else: ""

    case s.repeat do
      "once" ->
        {:ok, local} = DateTime.shift_zone(s.at, zone)

        "Once on #{Calendar.strftime(local, "%b %-d")} at #{Calendar.strftime(local, "%H:%M")} #{label(local)} for #{span}#{why}"

      repeat ->
        every =
          if repeat == "daily" or length(s.days) == 7,
            do: "Every day",
            else: "Every " <> Enum.map_join(s.days, ", ", &Enum.at(@weekdays, &1 - 1))

        "#{every} at #{s.time} #{zone_label(config)} for #{span}#{why}"
    end
  end

  defp label(%{zone_abbr: "UTC"}), do: "UTC"
  defp label(local), do: local.zone_abbr

  def length_text(seconds) do
    [{div(seconds, 3600), "h"}, {div(rem(seconds, 3600), 60), "m"}, {rem(seconds, 60), "s"}]
    |> Enum.reject(&(elem(&1, 0) == 0))
    |> Enum.map_join(" ", fn {n, unit} -> "#{n}#{unit}" end)
  end

  @doc "Once a minute: starts the windows that are due, for the time that is left of them."
  def run(now) do
    config = Alerts.config()
    zone = zone(config)
    for s <- Repo.all(from s in QuietSchedule, order_by: s.inserted_at), do: step(s, now, zone)
    :ok
  end

  defp step(%QuietSchedule{repeat: "once"} = s, now, _zone) do
    stop = DateTime.add(s.at, s.seconds)

    if DateTime.compare(now, s.at) != :lt do
      if DateTime.compare(now, stop) == :lt, do: begin(s, now, stop)
      Repo.delete(s)
    end
  end

  defp step(%QuietSchedule{} = s, now, zone) do
    today = today(now, zone)

    due =
      Enum.find_value([today, Date.add(today, -1)], fn date ->
        with true <- Date.day_of_week(date) in s.days and s.last_started_on != date,
             %DateTime{} = start <- instant(date, s.time, zone),
             stop = DateTime.add(start, s.seconds),
             true <- DateTime.compare(start, now) != :gt and DateTime.compare(now, stop) == :lt do
          {date, stop}
        else
          _ -> nil
        end
      end)

    with {date, stop} <- due do
      begin(s, now, stop)

      Repo.update_all(from(q in QuietSchedule, where: q.id == ^s.id),
        set: [last_started_on: date]
      )
    end
  end

  defp begin(s, now, stop) do
    running = Enum.find(Quiet.active(now), &(&1.machine_id == s.machine_id))

    unless running && DateTime.compare(running.until, stop) != :lt do
      left = max(DateTime.diff(stop, now, :second), 1)

      Quiet.start(
        s.machine_id,
        %{"for" => "#{left}s", "reason" => s.reason},
        "schedule (#{s.by})",
        now: now,
        hold: true
      )
    end
  end
end
