defmodule Dokkit.Numbers do
  @moduledoc """
  Numbers over time: what `metric` lines carry, and what is read out of a stats document.
  A threshold check goes bad when its metric is over its limit.
  """
  import Ecto.Query
  alias Dokkit.{Check, Issues, Metric, Repo, Service}

  @keep_days 30
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

    if is_nil(service) and not Repo.exists?(thresholds), do: machine_check(machine_id, name)

    # A threshold in a service's file reads that service's number, or the machine's.
    all = Repo.all(thresholds)
    limit_of = &limit/1
    declared? = Enum.any?(all, &(&1.source == :file and is_number(limit_of.(&1))))

    for check <- all,
        is_nil(service) or check.service_id == service.id,
        limit = limit_of.(check),
        is_number(limit) do
      # A declared threshold replaces the built-in one, which then reads as fine.
      if value > limit and not (declared? and check.source != :file),
        do:
          Issues.record(check, :down,
            at: at,
            value: value / 1,
            title: machine_title(check.config["limit_from"], name),
            note:
              "#{name} is #{round1(value)}, over the limit of #{limit}" <>
                full_in(check.config["full_in_days"])
          ),
        else: Issues.record(check, :ok, at: at, value: value / 1)
    end

    :ok
  end

  def record(_, _, _, _, _), do: {:error, "bad_line", "A metric needs a name and a number."}

  @machine_limits [{"disk.used_percent.", "disk_limit"}, {"memory.used_percent", "memory_limit"}]

  # A machine's own disk and memory are watched without anyone declaring it, against the
  # limits on the Alerts page. A threshold a file declares for the same number replaces this.
  defp machine_check(machine_id, name) do
    with {_, from} <-
           Enum.find(@machine_limits, fn {start, _} -> String.starts_with?(name, start) end) do
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

  defp full_in(days) when is_integer(days),
    do:
      ". At this week's rate it is full in about #{days} #{if days == 1, do: "day", else: "days"}."

  defp full_in(_), do: ""

  defp machine_title("disk_limit", name),
    do: "Disk #{String.replace_prefix(name, "disk.used_percent.", "")} is nearly full"

  defp machine_title("memory_limit", _), do: "Memory is nearly all in use"
  defp machine_title(_, _), do: nil

  @doc "A check's limit, from its own config or the Alerts page; nil when there is none."
  def limit(%Check{config: config}), do: config["limit"] || machine_limit(config["limit_from"])

  # nil when the limit on the Alerts page is blank, which switches it off.
  defp machine_limit(nil), do: nil

  defp machine_limit(setting) do
    case Float.parse(Dokkit.Alerts.config()[setting] || "") do
      {limit, _} -> limit
      :error -> nil
    end
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

  @forecast_days 14
  @disk "disk.used_percent."

  @doc """
  Once a sweep: a disk under its limit that a straight line through its last 7 days of
  readings carries to the limit within 14 days opens a soon issue, which closes when the
  line no longer gets there. A disk over its limit says in its note when it will be full.
  """
  def forecast(now \\ DateTime.utc_now()) do
    limit =
      case Float.parse(Dokkit.Alerts.config()["disk_limit"] || "") do
        {n, _} -> n
        :error -> nil
      end

    rows =
      Repo.all(
        from m in Metric,
          where: is_nil(m.service_id) and like(m.name, ^(@disk <> "%")),
          where: m.at > ^DateTime.add(now, -7 * 86_400),
          group_by: [m.machine_id, m.name],
          select: %{
            machine_id: m.machine_id,
            name: m.name,
            first: min(m.at),
            last: max(m.at),
            slope: fragment("regr_slope(?, extract(epoch from ?)::float8)", m.value, m.at),
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

    for r <- rows, limit, watched = checks[{r.machine_id, r.name}] do
      per_day = if r.slope, do: r.slope * 86_400, else: 0
      known = DateTime.diff(r.last, r.first) >= 2 * 86_400 and per_day > 0
      days = fn target -> max(1, round((target - r.current) / per_day)) end
      disk = String.replace_prefix(r.name, @disk, "")
      over? = r.current >= limit
      full = if known and over? and r.current < 100, do: days.(100)

      soon =
        if known and not over? and r.current + per_day * @forecast_days >= limit, do: days.(limit)

      if watched.config["full_in_days"] != full do
        config =
          if full,
            do: Map.put(watched.config, "full_in_days", full),
            else: Map.delete(watched.config, "full_in_days")

        Repo.update!(Ecto.Changeset.change(watched, config: config))
      end

      name = "forecast." <> r.name
      check = checks[{r.machine_id, name}]

      cond do
        soon ->
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
            note:
              "It is #{round1(r.current)} percent full. The limit is #{if limit == trunc(limit), do: trunc(limit), else: limit}."
          )

        check ->
          Issues.record(check, :ok, at: now)

        true ->
          nil
      end
    end

    :ok
  end

  defp round1(value), do: Float.round(value / 1, 1)

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

  @doc "One metric of a service as evenly spaced points, each the average of its slice of time."
  def series(service_id, name, from, to, points) do
    span = max(DateTime.diff(to, from, :millisecond), 1)

    rows =
      Repo.all(
        from m in Metric,
          where:
            m.service_id == ^service_id and m.name == ^name and m.at >= ^from and m.at <= ^to,
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

  def names(service_id) do
    Repo.all(
      from m in Metric,
        where: m.service_id == ^service_id,
        distinct: true,
        select: m.name,
        order_by: m.name
    )
  end

  def prune(now) do
    Repo.delete_all(from m in Metric, where: m.at < ^DateTime.add(now, -@keep_days * 86_400))
  end
end
