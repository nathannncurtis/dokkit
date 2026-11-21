defmodule Dokkit.Numbers do
  @moduledoc """
  Numbers over time: what `metric` lines carry, and what is read out of a stats document.
  A threshold check goes bad when its metric is past its limit: over, under, outside a band, or risen.
  """
  import Ecto.Query
  alias Dokkit.{Check, Issues, Metric, Repo, Service, Values}

  @disk "disk.used_percent."
  @max_document 256 * 1024

  @doc "Stores one number for a machine, or for one of its services."
  def record(machine_id, service, name, value, at) do
    {result, _} = record(context(machine_id), service, name, value, at, %{})
    result
  end

  @doc """
  What a batch of lines from one machine reads once instead of once a line: its name, its values
  and its threshold checks by metric. `record/6` hands back the context with the checks it changed.
  """
  def context(machine_id) do
    checks =
      Repo.all(
        from c in Check,
          join: s in assoc(c, :service),
          where: c.type == :threshold and s.machine_id == ^machine_id,
          preload: [service: s]
      )

    %{
      machine_id: machine_id,
      name: Repo.one(from m in Dokkit.Machine, where: m.id == ^machine_id, select: m.name),
      values: Values.all({:machine, machine_id}),
      own: Values.own({:machine, machine_id}),
      checks: Enum.group_by(checks, & &1.config["metric"])
    }
  end

  def record(ctx, service, name, value, at, extra) when is_binary(name) and is_number(value) do
    name = String.slice(name, 0, 100)

    Repo.insert!(%Metric{
      machine_id: ctx.machine_id,
      service_id: service && service.id,
      name: name,
      value: value / 1,
      at: at
    })

    values = ctx.values
    own = own_limit?(name, ctx.own)
    found = Map.get(ctx.checks, name, [])

    # A machine's own limit is watched even where a file declares one for the same number.
    made =
      if is_nil(service) and not Enum.any?(found, &Map.has_key?(&1.config, "limit_from")) and
           (own or found == []),
         do: machine_check(ctx.machine_id, name, value, values)

    all = found ++ List.wrap(made)

    # A threshold in a service's file reads that service's number, or the machine's.
    declared? =
      not own and Enum.any?(all, &(&1.source == :file and is_number(elem(levels(&1, values), 0))))

    all =
      for check <- all do
        if is_nil(service) or check.service_id == service.id do
          check = crit(check, extra["crit"])
          {limit, _} = levels(check, values)

          # A declared threshold replaces the built-in one, which then reads as fine; a machine's own setting replaces both.
          bad? =
            is_number(limit) and beyond?(direction(check), value, limit, check.value) and
              not (declared? and check.source != :file) and not (own and check.source == :file)

          judge(check, bad?, value, at, values, ctx.name)
        else
          check
        end
      end

    {:ok, put_in(ctx.checks[name], all)}
  end

  def record(ctx, _, _, _, _, _),
    do: {{:error, "bad_line", "A metric needs a name and a number."}, ctx}

  @doc "Whether a reading is past its limit: over it, under it, further than it from zero either way, or higher than the reading before."
  def beyond?(:over, value, limit, _), do: value > limit
  def beyond?(:under, value, limit, _), do: value < limit
  def beyond?(:band, value, limit, _), do: abs(value) > limit
  def beyond?(:rose, value, _, previous), do: is_number(previous) and value > previous

  # The limits every machine has without anyone declaring them: {name prefix, name suffix,
  # direction, settings row}. A prefix that ends in a dot needs something between it and the suffix.
  @machine_limits [
    {"disk.used_percent.", "", :over, "disk"},
    {"memory.used_percent", "", :over, "memory"},
    {"cpu.percent", "", :over, "cpu"},
    {"gpu.", ".temp_c", :over, "gpu_temp"},
    {"gpu.", ".memory_percent", :over, "gpu_memory"},
    {"temp.cpu_c", "", :over, "cpu_temp"},
    {"temp.cpu.", "_c", :over, "cpu_temp"},
    {"temp.ambient_c", "", :over, "ambient_temp"},
    {"temp.system_c", "", :over, "ambient_temp"},
    {"fan.", "_rpm", :under, "fan_stop"},
    {"clock.offset_seconds", "", :band, "clock"}
  ]

  # These count readings in a row, as they always have; every other row counts minutes, which
  # holds when an unchanged reading is sent less often.
  @by_readings ~w(disk_limit memory_limit cpu_limit)

  def machine_limits, do: @machine_limits

  defp limit_entry(name) do
    Enum.find(@machine_limits, fn {prefix, suffix, _, _} ->
      middle = byte_size(name) - byte_size(prefix) - byte_size(suffix)

      String.starts_with?(name, prefix) and String.ends_with?(name, suffix) and
        if(String.ends_with?(prefix, "."), do: middle > 0, else: middle == 0)
    end)
  end

  defp limit_from(name) do
    case limit_entry(name) do
      {_, _, _, row} -> row <> "_limit"
      nil -> nil
    end
  end

  defp row(from), do: String.replace_suffix(from, "_limit", "")

  defp direction(%Check{config: %{"limit_from" => _}, name: name}) do
    case limit_entry(name) do
      {_, _, dir, _} -> dir
      nil -> :over
    end
  end

  defp direction(_), do: :over

  defp own_limit?(name, own) do
    case limit_from(name) do
      nil ->
        false

      from when from in @by_readings ->
        Map.has_key?(own, from) or Map.has_key?(own, row(from) <> "_on")

      from ->
        Enum.any?(~w(_on _limit _down _minutes), &Map.has_key?(own, row(from) <> &1))
    end
  end

  @doc "The service that holds a machine's own checks, made the first time it is needed."
  def own_service(machine_id) do
    Repo.get_by(Service, machine_id: machine_id, slug: "machine") ||
      Repo.insert!(%Service{machine_id: machine_id, slug: "machine", name: "The machine itself"})
  end

  # A machine's own numbers are watched without anyone declaring it, against the limits in
  # Settings. A threshold a file declares for the same number replaces this. A number watched
  # for going under its limit is watched once it has been above it: a fan that never turns is not.
  defp machine_check(machine_id, name, value, values) do
    with from when is_binary(from) <- limit_from(name),
         true <- from != "cpu_limit" or values["cpu_on"],
         true <-
           direction(%Check{name: name, config: %{"limit_from" => from}}) != :under or
             (values[row(from) <> "_on"] and value >= values[from]) do
      service = own_service(machine_id)

      %{
        Repo.insert!(%Check{
          service_id: service.id,
          name: name,
          type: :threshold,
          config: %{"metric" => name, "limit_from" => from}
        })
        | service: service
      }
    else
      _ -> nil
    end
  end

  # A sensor that names its own critical temperature keeps it on its check, for the limit.
  defp crit(%Check{config: %{"limit_from" => "cpu_temp_limit"} = config} = check, crit)
       when is_number(crit) and crit > 10 do
    if config["crit"] == crit,
      do: check,
      else: set_config(check, Map.put(config, "crit", crit))
  end

  defp crit(check, _), do: check

  # The slow and down levels of a check. A sensor's own critical temperature counts while the setting is on its default.
  defp levels(%Check{config: %{"limit_from" => from} = config}, values) do
    row = row(from)
    down = row <> "_down"

    cond do
      not values[row <> "_on"] ->
        {nil, nil}

      is_number(config["crit"]) and values[from] == Values.default(from) and
          values[down] == Values.default(down) ->
        {config["crit"] - 10.0, config["crit"] / 1}

      true ->
        {values[from] / 1, values[down]}
    end
  end

  defp levels(%Check{config: config}, _), do: {config["limit"], nil}

  # A row counted in minutes opens once its readings have been past the limit that long.
  defp judge(%Check{config: %{"limit_from" => from}} = check, bad?, value, at, values, machine)
       when from not in @by_readings do
    since = check.config["over_since"]

    check =
      cond do
        bad? and is_nil(since) ->
          set_config(check, Map.put(check.config, "over_since", DateTime.to_iso8601(at)))

        not bad? and since ->
          set_config(check, Map.delete(check.config, "over_since"))

        true ->
          check
      end

    started = if since, do: elem(DateTime.from_iso8601(since), 1), else: at
    need = values[row(from) <> "_minutes"] * 60 - values["report_seconds"]
    once = %{check | fail_after: 1, config: Map.put(check.config, "own_fail_after", true)}

    cond do
      not bad? ->
        Issues.record(once, :ok, at: at, value: value / 1)

      DateTime.diff(at, started) >= need ->
        opened(once, value, at, values, machine)

      true ->
        check
    end
    |> kept(check)
  end

  defp opened(check, value, at, values, machine) do
    {limit, down} = levels(check, values)

    Issues.record(check, level(direction(check), value, down),
      at: at,
      value: value / 1,
      title: hardware_title(check.name, value, machine),
      note: hardware_note(check.name, direction(check), value, limit)
    )
  end

  @doc "Each minute: opens a minutes-counted limit whose time is up, since an unchanged reading is re-sent only every five minutes."
  def overdue(now \\ DateTime.utc_now()) do
    checks =
      Repo.all(
        from c in Check,
          join: s in assoc(c, :service),
          join: m in assoc(s, :machine),
          where: c.type == :threshold and fragment("? \\? 'over_since'", c.config),
          where: c.state not in [:degraded, :down],
          preload: [service: {s, machine: m}]
      )

    for %Check{service: %{machine: machine}} = check <- checks do
      values = Values.all({:machine, machine.id})
      {:ok, since, _} = DateTime.from_iso8601(check.config["over_since"])
      need = values[row(check.config["limit_from"]) <> "_minutes"] * 60 - values["report_seconds"]
      {limit, _} = levels(check, values)

      latest =
        Repo.one(
          from m in Metric,
            where: m.machine_id == ^machine.id and is_nil(m.service_id) and m.name == ^check.name,
            order_by: [desc: m.at],
            limit: 1,
            select: m.value
        )

      reporting? =
        machine.last_seen_at &&
          DateTime.diff(now, machine.last_seen_at) <= 2 * values["report_seconds"] + 60

      if reporting? and is_number(latest) and is_number(limit) and
           DateTime.diff(now, since) >= need and
           beyond?(direction(check), latest, limit, nil) do
        once = %{check | fail_after: 1, config: Map.put(check.config, "own_fail_after", true)}
        opened(once, latest, now, values, machine.name)
      end
    end

    :ok
  end

  defp judge(check, bad?, value, at, values, _) do
    {limit, _} = levels(check, values)
    counted = readings(check, values)

    if bad? do
      Issues.record(counted, over_state(counted, value, values),
        at: at,
        value: value / 1,
        title: machine_title(check.config["limit_from"], check.name),
        note: over_note(check.name, value, limit) <> full_in(check.config["full_in_days"])
      )
    else
      Issues.record(counted, :ok, at: at, value: value / 1)
    end
    |> kept(check)
  end

  # The recorded check as the next line of the batch reads it: its counts, with its own config and service.
  defp kept(recorded, check),
    do: %{recorded | service: check.service, fail_after: check.fail_after, config: check.config}

  defp set_config(check, config), do: Repo.update!(Ecto.Changeset.change(check, config: config))

  # How far past its down level a reading is, so one rule serves every direction.
  defp level(dir, value, down) do
    measure = fn v ->
      case dir do
        :band -> abs(v)
        :under -> -v
        _ -> v
      end
    end

    if is_number(down) and measure.(value) >= measure.(down), do: :down, else: :degraded
  end

  # Over a limit from Settings is a struggle, and a failure from its down level. A limit a file declares is a failure.
  defp over_state(%Check{config: %{"limit_from" => from}}, value, values) do
    down = values[row(from) <> "_down"]
    if is_nil(down) or value < down, do: :degraded, else: :down
  end

  defp over_state(_, _, _), do: :down

  # Readings in a row as the machine's settings say. The minutes of the processor become readings.
  defp readings(%Check{config: %{"limit_from" => from} = config} = check, values) do
    n =
      if from == "cpu_limit",
        do: max(1, ceil(values["cpu_minutes"] * 60 / values["report_seconds"])),
        else: values[row(from) <> "_after"]

    %{check | fail_after: n, config: Map.put(config, "own_fail_after", true)}
  end

  defp readings(check, _), do: check

  defp over_note(@disk <> _, value, limit),
    do: "It is #{num(value)} percent full. The limit is #{num(limit)}."

  defp over_note(name, value, limit),
    do: "#{name} is #{num(value)}, over the limit of #{num(limit)}."

  @doc "How a hardware number's unit is written after it."
  def unit(name) do
    cond do
      String.ends_with?(name, "_c") -> " °C"
      String.ends_with?(name, "_percent") -> "%"
      String.ends_with?(name, "_rpm") -> " RPM"
      String.ends_with?(name, "_w") -> " W"
      String.ends_with?(name, "_seconds") -> " seconds"
      true -> ""
    end
  end

  defp hardware_note(name, :band, value, limit),
    do: "It is #{num(abs(value))}#{unit(name)} off. The limit is #{num(limit)}#{unit(name)}."

  defp hardware_note(name, _, value, limit),
    do: "It is #{num(value)}#{unit(name)}. The limit is #{num(limit)}#{unit(name)}."

  @doc "A hardware issue's title: a sentence with the reading and the machine."
  def hardware_title(name, value, machine) do
    at = "#{num(value)}#{unit(name)}"

    what =
      case String.split(name, ".") do
        ["gpu", "0", "temp_c"] ->
          "GPU at #{at}"

        ["gpu", n, "temp_c"] ->
          "GPU #{n} at #{at}"

        ["gpu", "0", "memory_percent"] ->
          "GPU memory at #{at}"

        ["gpu", n, "memory_percent"] ->
          "GPU #{n} memory at #{at}"

        ["temp", "cpu_c"] ->
          "Processor at #{at}"

        ["temp", "cpu", n] ->
          "Processor #{String.trim_trailing(n, "_c")} at #{at}"

        ["temp", "ambient_c"] ->
          "Air at #{at}"

        ["temp", "system_c"] ->
          "Inside the case at #{at}"

        ["fan", fan] ->
          "Fan #{fan |> String.trim_trailing("_rpm") |> String.replace("_", " ")} stopped"

        ["clock", _] ->
          "Clock #{num(abs(value))} seconds #{if value > 0, do: "ahead", else: "behind"}"

        _ ->
          "#{name} at #{at}"
      end

    "#{what} on #{machine}"
  end

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

    elem(levels(check, values), 0)
  end

  # nil when the limit is switched off.
  defp machine_limit(setting, values) do
    if values[row(setting) <> "_on"], do: values[setting] / 1
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

  @hardware ~w(gpu. temp. fan. clock.)

  @doc "Whether a machine's own number is a hardware reading, shown in its own section and kept for its own time."
  def hardware?(name), do: String.starts_with?(name, @hardware)

  def prune(now) do
    days = Values.get("metrics_days")
    hardware = Values.get("hardware_days")
    pattern = "^(gpu|temp|fan|clock)\\."

    Repo.delete_all(
      from m in Metric,
        where: m.at < ^DateTime.add(now, -hardware * 86_400),
        where: is_nil(m.service_id) and fragment("? ~ ?", m.name, ^pattern)
    )

    Repo.delete_all(
      from m in Metric,
        where: m.at < ^DateTime.add(now, -days * 86_400),
        where: not is_nil(m.service_id) or fragment("? !~ ?", m.name, ^pattern)
    )
  end
end
