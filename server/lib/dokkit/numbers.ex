defmodule Dokkit.Numbers do
  @moduledoc """
  Numbers over time: what `metric` lines carry, and what is read out of a stats document.
  A threshold check goes bad when its metric is over its limit.
  """
  import Ecto.Query
  alias Dokkit.{Check, Issues, Metric, Repo, Service, Values}

  @disk "disk.used_percent."
  @max_document 256 * 1024

  @doc "Stores one number for a machine, or for one of its services."
  def record(machine_id, service, name, value, at)
      when is_binary(name) and is_number(value) do
    name = String.slice(name, 0, 100)

    Repo.insert!(%Metric{
      machine_id: machine_id,
      service_id: service && service.id,
      name: name,
      value: value / 1,
      at: at
    })

    thresholds =
      from c in Check,
        join: s in assoc(c, :service),
        where: c.type == :threshold and s.machine_id == ^machine_id,
        where: fragment("?->>'metric' = ?", c.config, ^name),
        preload: [service: s]

    values = Values.all({:machine, machine_id})
    own = own_limit?(name, machine_id)

    # A machine's own limit is watched even where a file declares one for the same number.
    if is_nil(service) and
         not Repo.exists?(from c in thresholds, where: fragment("? \\? 'limit_from'", c.config)) and
         (own or not Repo.exists?(thresholds)),
       do: machine_check(machine_id, name, values)

    # A threshold in a service's file reads that service's number, or the machine's.
    all = Repo.all(thresholds)
    limit_of = &limit_with(&1, values)
    declared? = not own and Enum.any?(all, &(&1.source == :file and is_number(limit_of.(&1))))

    for check <- all,
        is_nil(service) or check.service_id == service.id do
      limit = limit_of.(check)
      check = readings(check, values)

      # A declared threshold replaces the built-in one, which then reads as fine; a machine's own setting replaces both.
      if is_number(limit) and value > limit and not (declared? and check.source != :file) and
           not (own and check.source == :file),
         do:
           Issues.record(check, over_state(check, value, values),
             at: at,
             value: value / 1,
             title: machine_title(check.config["limit_from"], name),
             note: over_note(name, value, limit) <> full_in(check.config["full_in_days"])
           ),
         else: Issues.record(check, :ok, at: at, value: value / 1)
    end

    :ok
  end

  def record(_, _, _, _, _), do: {:error, "bad_line", "A metric needs a name and a number."}

  @machine_limits [
    {"disk.used_percent.", "disk_limit"},
    {"memory.used_percent", "memory_limit"},
    {"cpu.percent", "cpu_limit"}
  ]
  @limit_rows %{"disk_limit" => "disk", "memory_limit" => "memory", "cpu_limit" => "cpu"}

  defp limit_from(name) do
    Enum.find_value(@machine_limits, fn {start, from} ->
      if name == start or (String.ends_with?(start, ".") and String.starts_with?(name, start)),
        do: from
    end)
  end

  defp own_limit?(name, machine_id) do
    case limit_from(name) do
      nil ->
        false

      from ->
        own = Values.own({:machine, machine_id})
        Map.has_key?(own, from) or Map.has_key?(own, @limit_rows[from] <> "_on")
    end
  end

  # A machine's own disk, memory and processor are watched without anyone declaring it, against
  # the limits in Settings. A threshold a file declares for the same number replaces this.
  defp machine_check(machine_id, name, values) do
    with from when is_binary(from) <- limit_from(name),
         true <- from != "cpu_limit" or values["cpu_on"] do
      service =
        Repo.get_by(Service, machine_id: machine_id, slug: "machine") ||
          Repo.insert!(%Service{
            machine_id: machine_id,
            slug: "machine",
            name: "The machine itself"
          })

      Repo.insert!(%Check{
        service_id: service.id,
        name: name,
        type: :threshold,
        config: %{"metric" => name, "limit_from" => from}
      })
    end
  end

  # Over a limit from Settings is a struggle, and a failure from its down level. A limit a file declares is a failure.
  defp over_state(%Check{config: %{"limit_from" => from}}, value, values) do
    down = values[@limit_rows[from] <> "_down"]
    if is_nil(down) or value < down, do: :degraded, else: :down
  end

  defp over_state(_, _, _), do: :down

  # Readings in a row as the machine's settings say. The minutes of the processor become readings.
  defp readings(%Check{config: %{"limit_from" => from} = config} = check, values) do
    n =
      if from == "cpu_limit",
        do: max(1, ceil(values["cpu_minutes"] * 60 / values["report_seconds"])),
        else: values[@limit_rows[from] <> "_after"]

    %{check | fail_after: n, config: Map.put(config, "own_fail_after", true)}
  end

  defp readings(check, _), do: check

  defp over_note(@disk <> _, value, limit),
    do: "It is #{num(value)} percent full. The limit is #{num(limit)}."

  defp over_note(name, value, limit),
    do: "#{name} is #{num(value)}, over the limit of #{num(limit)}."

  @full_in ~r/ At this week's rate it is full in about \d+ days?\./

  defp full_in(days) when is_integer(days),
    do:
      " At this week's rate it is full in about #{days} #{if days == 1, do: "day", else: "days"}."

  defp full_in(_), do: ""

  # Whole numbers are written whole.
  defp num(value) do
    value = value / 1
    if value == Float.round(value), do: trunc(value), else: Float.round(value, 1)
  end

  defp machine_title("disk_limit", name),
    do: "Disk #{String.replace_prefix(name, "disk.used_percent.", "")} is nearly full"

  defp machine_title("memory_limit", _), do: "Memory is nearly all in use"
  defp machine_title("cpu_limit", _), do: "The processor is busy"
  defp machine_title(_, _), do: nil

  @doc "A check's limit, from its own config or its machine's settings; nil when there is none."
  def limit(%Check{} = check) do
    machine_id =
      check.config["limit_from"] &&
        case check.service do
          %Service{machine_id: id} ->
            id

          _ ->
            Repo.one(from s in Service, where: s.id == ^check.service_id, select: s.machine_id)
        end

    values =
      cond do
        is_nil(check.config["limit_from"]) -> nil
        is_nil(machine_id) -> Values.all()
        true -> Values.all({:machine, machine_id})
      end

    limit_with(check, values)
  end

  defp limit_with(%Check{config: config}, values),
    do: config["limit"] || machine_limit(config["limit_from"], values)

  # nil when the limit is switched off.
  defp machine_limit(nil, _), do: nil

  defp machine_limit(setting, values) do
    if values[@limit_rows[setting] <> "_on"], do: values[setting] / 1
  end

  @doc "Keeps a service's latest stats document and the numbers worth charting from it."
  def stats(%Service{} = service, %{"schema" => 1} = document, at) do
    if byte_size(Jason.encode!(document)) > @max_document do
      {:error, "too_large", "A stats document is at most 256 KB."}
    else
      Repo.update!(Ecto.Changeset.change(service, stats: document, stats_at: at))
      if is_binary(document["version"]), do: Dokkit.Deploys.record(service, document["version"])

      for {name, key} <- [
            {"requests.per_minute", "per_minute"},
            {"requests.error_rate", "error_rate"},
            {"requests.p95_ms", "p95_ms"}
          ],
          value = get_in(document, ["requests", "5m", key]),
          is_number(value),
          do: record(service.machine_id, service, name, value, at)

      :ok
    end
  end

  def stats(_, _, _), do: {:error, "bad_line", "Needs a stats document with schema 1."}

  @doc """
  Every half hour: a disk under its limit that is rising over at least 4 days of readings,
  in the whole of its last 7 days and in each half of them, and whose slowest such rise carries
  it to the limit within 14 days opens a soon issue. A step up that then stays flat is not a
  rise. It closes when the line is more than 16 days from the limit, the limit is switched off,
  or the readings stop; an over-limit issue of a disk that is no longer reported closes too.
  A disk over its limit says in its note when it will be full, if that is within 60 days.
  Each number is a setting. Once soon, a disk stays soon until it is further than the second
  number of days from its limit, so noise does not flap it.
  """
  def forecast(now \\ DateTime.utc_now()) do
    server = Values.all()
    window = server["forecast_window_days"] * 86_400
    middle = DateTime.add(now, -div(window, 2))

    rows =
      Repo.all(
        from m in Metric,
          where: is_nil(m.service_id) and like(m.name, ^(@disk <> "%")),
          where: m.at > ^DateTime.add(now, -window),
          group_by: [m.machine_id, m.name],
          select: %{
            machine_id: m.machine_id,
            name: m.name,
            first: min(m.at),
            last: max(m.at),
            slopes:
              fragment(
                "array[regr_slope(?, extract(epoch from ?)::float8), regr_slope(?, extract(epoch from ?)::float8) filter (where ? < ?), regr_slope(?, extract(epoch from ?)::float8) filter (where ? >= ?)]",
                m.value,
                m.at,
                m.value,
                m.at,
                m.at,
                ^middle,
                m.value,
                m.at,
                m.at,
                ^middle
              ),
            current: fragment("(array_agg(? order by ? desc))[1]", m.value, m.at)
          }
      )

    ids = Enum.map(rows, & &1.machine_id)

    names =
      Map.new(Repo.all(from m in Dokkit.Machine, where: m.id in ^ids, select: {m.id, m.name}))

    checks =
      Repo.all(
        from c in Check,
          join: s in assoc(c, :service),
          where: s.slug == "machine" and s.machine_id in ^ids,
          preload: [service: s]
      )
      |> Map.new(&{{&1.service.machine_id, &1.name}, &1})

    values = Map.new(ids, &{&1, Values.all({:machine, &1})})
    limit_of = fn id -> machine_limit("disk_limit", values[id]) end

    soon_ids =
      for r <- rows,
          limit = limit_of.(r.machine_id),
          watched = checks[{r.machine_id, r.name}],
          reduce: [] do
        kept ->
          v = values[r.machine_id]
          per_day = if Enum.all?(r.slopes), do: Enum.min(r.slopes) * 86_400, else: 0

          known =
            DateTime.diff(r.last, r.first) >= server["forecast_min_days"] * 86_400 and
              DateTime.diff(now, r.last) <= 86_400 and per_day > 0

          days = fn target -> max(1, round((target - r.current) / per_day)) end
          disk = String.replace_prefix(r.name, @disk, "")
          over? = r.current >= limit

          full =
            if known and over? and r.current < 100 and days.(100) <= v["forecast_full_days"],
              do: days.(100)

          name = "forecast." <> r.name
          check = checks[{r.machine_id, name}]

          horizon =
            if check && check.state == :degraded,
              do: v["forecast_clear_days"],
              else: v["forecast_days"]

          soon =
            if known and not over? and r.current + per_day * horizon >= limit, do: days.(limit)

          set_full(watched, full)

          if soon do
            check =
              check ||
                Repo.insert!(%Check{
                  service_id: watched.service_id,
                  name: name,
                  type: :custom,
                  fail_after: 1
                })

            Issues.record(check, :degraded,
              at: now,
              soon: true,
              title:
                "Disk #{disk} on #{names[r.machine_id]} fills in about #{soon} #{if soon == 1, do: "day", else: "days"}",
              note: "It is #{num(r.current)} percent full. The limit is #{num(limit)}."
            )

            [check.id | kept]
          else
            kept
          end
      end

    # What no longer has a reason to be soon closes, including when there is no limit or no readings.
    for c <-
          Repo.all(
            from c in Check,
              join: s in assoc(c, :service),
              where: s.slug == "machine" and like(c.name, "forecast.%") and c.state != :ok,
              select: c
          ),
        c.id not in soon_ids,
        do: Issues.record(c, :ok, at: now)

    fresh = for r <- rows, DateTime.diff(now, r.last) <= 86_400, do: {r.machine_id, r.name}

    for c <-
          Repo.all(
            from c in Check,
              join: s in assoc(c, :service),
              where: s.slug == "machine" and like(c.name, ^(@disk <> "%")) and c.state != :ok,
              preload: [service: s]
          ),
        {c.service.machine_id, c.name} not in fresh,
        do: Issues.record(%{c | passes: Issues.fail_after(c)}, :ok, at: now)

    # A full-in-days note whose disk has no limit or no readings now is stale.
    live = for r <- rows, limit_of.(r.machine_id), c = checks[{r.machine_id, r.name}], do: c.id

    for c <-
          Repo.all(
            from c in Check,
              join: s in assoc(c, :service),
              where: s.slug == "machine" and fragment("? \\? 'full_in_days'", c.config),
              preload: [service: s]
          ),
        c.id not in live,
        do: set_full(c, nil)

    :ok
  end

  # The note of an over-limit disk says when it will be full as soon as that is known.
  defp set_full(%Check{config: config} = watched, full) do
    if config["full_in_days"] != full do
      config =
        if full,
          do: Map.put(config, "full_in_days", full),
          else: Map.delete(config, "full_in_days")

      note = watched.note && Regex.replace(@full_in, watched.note, "") <> full_in(full)
      Repo.update!(Ecto.Changeset.change(watched, config: config, note: note))
      if note != watched.note, do: Issues.refresh(watched.service)
    end
  end

  @doc "The latest machine-wide numbers of every machine, as %{machine id => %{name => value}}."
  def vitals do
    since = DateTime.add(DateTime.utc_now(), -600)

    Repo.all(
      from m in Metric,
        where: is_nil(m.service_id) and m.at > ^since,
        distinct: [m.machine_id, m.name],
        order_by: [m.machine_id, m.name, desc: m.at],
        select: {m.machine_id, m.name, m.value}
    )
    |> Enum.group_by(&elem(&1, 0), fn {_, name, value} -> {name, value} end)
    |> Map.new(fn {id, pairs} -> {id, Map.new(pairs)} end)
  end

  @doc """
  One metric of a service, or of a machine itself as `{:machine, id}`, as evenly spaced points,
  each the average of its slice of time.
  """
  def series(owner, name, from, to, points) do
    span = max(DateTime.diff(to, from, :millisecond), 1)

    rows =
      Repo.all(
        from m in Metric,
          where: ^owned(owner),
          where: m.name == ^name and m.at >= ^from and m.at <= ^to,
          select: {m.at, m.value}
      )

    slices =
      Enum.group_by(
        rows,
        fn {at, _} ->
          min(div(DateTime.diff(at, from, :millisecond) * points, span), points - 1)
        end,
        &elem(&1, 1)
      )

    for i <- 0..(points - 1) do
      values = slices[i]

      %{
        at: DateTime.add(from, div(span * i, points), :millisecond),
        value: values && Enum.sum(values) / length(values)
      }
    end
  end

  defp owned({:machine, id}), do: dynamic([m], m.machine_id == ^id and is_nil(m.service_id))
  defp owned(service_id), do: dynamic([m], m.service_id == ^service_id)

  def names(owner) do
    Repo.all(
      from m in Metric,
        where: ^owned(owner),
        distinct: true,
        select: m.name,
        order_by: m.name
    )
  end

  @doc "The latest reading of each of a machine's own numbers, as [%{name, value, at}]."
  def machine_latest(machine_id) do
    Repo.all(
      from m in Metric,
        where: ^owned({:machine, machine_id}),
        distinct: m.name,
        order_by: [m.name, desc: m.at],
        select: %{name: m.name, value: m.value, at: m.at}
    )
  end

  def prune(now) do
    days = Values.get("metrics_days")
    Repo.delete_all(from m in Metric, where: m.at < ^DateTime.add(now, -days * 86_400))
  end
end
