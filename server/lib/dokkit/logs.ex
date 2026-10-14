defmodule Dokkit.Logs do
  @moduledoc "Log lines. Stored one partition per month; see spec/log-lines.md."
  import Ecto.Query
  alias Dokkit.{Log, Repo}

  @levels ~w(trace debug info warn error fatal)
  @clef (for {names, level} <- [
              {~w(verbose vrb v silly trace trc), "trace"},
              {~w(debug dbg d), "debug"},
              {~w(information info inf i), "info"},
              {~w(warning warn wrn w), "warn"},
              {~w(error err e), "error"},
              {~w(fatal ftl f critical crit), "fatal"}
            ],
            name <- names,
            into: %{},
            do: {name, level})
  @max_msg 64 * 1024

  def levels, do: @levels

  @doc """
  Turns a report line, in Dokkit's format or CLEF, into a row. A line without a message is kept
  whole as its message. `received_at` is the server's time; `at` is the sender's.
  """
  def row(line, machine_id, service_id, received_at) do
    clef? = Map.has_key?(line, "@t") or Map.has_key?(line, "@m") or Map.has_key?(line, "@mt")
    msg = if clef?, do: line["@m"] || render(line["@mt"], line), else: line["msg"]
    msg = if is_binary(msg), do: msg, else: Jason.encode!(line)

    level =
      if clef?,
        do: @clef[String.downcase(to_string(line["@l"] || "information"))],
        else: line["level"]

    known =
      if clef?,
        do: ~w(@t @l @m @mt @x @i @r type at service),
        else: ~w(t level msg fields type at service)

    extra =
      if clef?,
        do: Map.drop(line, known),
        else: (is_map(line["fields"]) && line["fields"]) || %{}

    extra = if clef? and line["@x"], do: Map.put(extra, "exception", line["@x"]), else: extra
    cut = byte_size(msg) > @max_msg
    big = byte_size(Jason.encode!(extra)) > @max_msg

    %{
      at: time(line["t"] || line["@t"] || line["at"], DateTime.utc_now()),
      received_at: received_at,
      machine_id: machine_id,
      service_id: service_id,
      level: if(level in @levels, do: level, else: "info"),
      msg: if(cut, do: msg |> binary_part(0, @max_msg) |> String.replace_invalid(""), else: msg),
      fields: if(big, do: %{}, else: extra),
      cut: cut or big
    }
  end

  def insert([]), do: 0

  def insert(rows) do
    rows |> Enum.chunk_every(2000) |> Enum.each(&Repo.insert_all(Log, &1))
    Phoenix.PubSub.broadcast(Dokkit.PubSub, "logs", :logs_changed)
    length(rows)
  end

  def subscribe, do: Phoenix.PubSub.subscribe(Dokkit.PubSub, "logs")

  @doc "Newest first. Options: q, level (that level and worse), service, machine, from, to, limit."
  def list(opts \\ []) do
    query =
      from l in Log,
        order_by: [desc: l.at, desc: l.id],
        limit: ^(opts[:limit] || 200),
        preload: [:machine, :service]

    query = if opts[:service], do: where(query, [l], l.service_id == ^opts[:service]), else: query
    query = if opts[:machine], do: where(query, [l], l.machine_id == ^opts[:machine]), else: query
    query = if opts[:from], do: where(query, [l], l.at >= ^opts[:from]), else: query
    query = if opts[:to], do: where(query, [l], l.at <= ^opts[:to]), else: query

    query =
      case opts[:before] do
        {at, id} -> where(query, [l], l.at < ^at or (l.at == ^at and l.id < ^id))
        _ -> query
      end

    query =
      case Enum.find_index(@levels, &(&1 == opts[:level])) do
        nil -> query
        i -> where(query, [l], l.level in ^Enum.drop(@levels, i))
      end

    query =
      case String.trim(opts[:q] || "") do
        "" ->
          query

        q ->
          where(
            query,
            [l],
            ilike(l.msg, ^"%#{String.replace(q, ["\\", "%", "_"], &("\\" <> &1))}%")
          )
      end

    Repo.all(query)
  end

  @move_batch 20_000

  @doc """
  Moves the lines of service `from` to service `to`, in batches of 20,000 so no statement runs
  long. `opts`: `field` and `values` (only lines whose `fields[field]` is one of them), `from` and
  `until` (a time range, `until` exclusive), `dry` (count only). Returns the number of lines.
  """
  def move(from, to, opts \\ []) do
    base =
      Enum.reduce(opts, from(l in Log, where: l.service_id == ^from), fn
        {:field, field}, q ->
          values = opts[:values]

          where(
            q,
            [l],
            fragment("?->>?", l.fields, type(^field, :string)) in type(^values, {:array, :string})
          )

        {:from, at}, q ->
          where(q, [l], l.at >= ^at)

        {:until, at}, q ->
          where(q, [l], l.at < ^at)

        _, q ->
          q
      end)

    if opts[:dry] do
      Repo.aggregate(base, :count, timeout: 120_000)
    else
      machine = Repo.one(from s in Dokkit.Service, where: s.id == ^to, select: s.machine_id)
      set = if machine, do: [service_id: to, machine_id: machine], else: [service_id: to]
      move_batches(base, set, 0)
    end
  end

  defp move_batches(base, set, total) do
    ids = from l in base, select: l.id, limit: @move_batch

    {n, _} =
      Repo.update_all(from(l in Log, where: l.id in subquery(ids)), [set: set], timeout: 120_000)

    if n == 0, do: total, else: move_batches(base, set, total + n)
  end

  @doc "Makes the month's partition for a line, or for a date, if it is not there yet."
  def ensure_partition(%{} = line, now),
    do: ensure_partition(time(line["t"] || line["@t"] || line["at"], now))

  def ensure_partition(%{year: year, month: month}) do
    key = {year, month}

    unless :persistent_term.get({__MODULE__, key}, false) do
      from = Date.new!(year, month, 1)
      to = Date.shift(from, month: 1)
      name = "logs_y#{year}m#{String.pad_leading(to_string(month), 2, "0")}"

      Repo.query!(
        "CREATE TABLE IF NOT EXISTS #{name} PARTITION OF logs FOR VALUES FROM ('#{from} 00:00:00+00') TO ('#{to} 00:00:00+00')"
      )

      :persistent_term.put({__MODULE__, key}, true)
    end
  end

  @defaults %{"months" => 12, "action" => "archive"}

  def retention do
    saved = (Repo.get(Dokkit.Setting, "log_retention") || %Dokkit.Setting{value: %{}}).value
    Map.merge(@defaults, saved)
  end

  @doc "Saves how many months stay live (1 to 120) and what happens to an older month. Deleting needs `confirm`."
  def save_retention(params) do
    current = retention()
    months = Map.get(params, "months", current["months"])
    months = if is_binary(months), do: Integer.parse(String.trim(months)), else: {months, ""}
    action = Map.get(params, "action", current["action"])

    cond do
      not match?({n, ""} when is_integer(n) and n in 1..120, months) ->
        {:error, "months is a whole number from 1 to 120."}

      action not in ~w(archive delete) ->
        {:error, "action is archive or delete."}

      action == "delete" and params["confirm"] not in [true, "true"] ->
        {:error, "Deleting old logs needs confirm: true. Deleted logs are not archived."}

      true ->
        new = %{"months" => elem(months, 0), "action" => action}

        Repo.insert!(%Dokkit.Setting{key: "log_retention", value: new},
          on_conflict: {:replace, [:value, :updated_at]},
          conflict_target: :key
        )

        {:ok, new}
    end
  end

  def retention_view do
    r = retention()
    Map.put(r, "older", length(older(r["months"])))
  end

  @doc "The months in the database, oldest first, as `{table, year, month}`."
  def months do
    Repo.query!("""
    SELECT c.relname FROM pg_inherits i
    JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_class p ON p.oid = i.inhparent
    WHERE p.relname = 'logs' ORDER BY 1
    """).rows
    |> Enum.flat_map(fn [name] ->
      case Regex.run(~r/^logs_y(\d{4})m(\d{2})$/, name) do
        [_, year, month] -> [{name, year, month}]
        _ -> []
      end
    end)
  end

  @doc "The months that are older than `keep` months before `today`'s month."
  def older(keep, today \\ Date.utc_today()) do
    cutoff = Date.shift(Date.beginning_of_month(today), month: -keep)

    Enum.filter(months(), fn {_, year, month} ->
      Date.compare(Date.new!(String.to_integer(year), String.to_integer(month), 1), cutoff) == :lt
    end)
  end

  @doc """
  Writes each month older than the live limit to one compressed file in `dir` and drops it from
  the database, or only drops it when the setting is `delete`. Returns the files written, or
  the dropped tables when deleting. A month is read whole into memory to be written.
  """
  def archive(dir, today \\ Date.utc_today()) do
    %{"months" => keep, "action" => action} = retention()
    back = restored()
    held = for {name, until} <- back, until > DateTime.utc_now(), do: name

    for {name, year, month} <- older(keep, today),
        key = {String.to_integer(year), String.to_integer(month)},
        "logs-#{year}-#{month}" not in held,
        action == "delete" or is_binary(dir) do
      if action == "delete" do
        Repo.query!("DROP TABLE #{name}")
        :persistent_term.erase({__MODULE__, key})
        name
      else
        archive_month(dir, back, name, year, month, key)
      end
    end
  end

  defp archive_month(dir, back, name, year, month, key) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "logs-#{year}-#{month}.ndjson.gz")

    # A month that came back from its file is only dropped; any other month is written out
    # first, under a free name. Written as .part first so a half file is never an archive.
    path =
      if "logs-#{year}-#{month}" in Map.keys(back) and File.exists?(path) do
        path
      else
        %{rows: rows} =
          Repo.query!("SELECT row_to_json(l)::text FROM #{name} l ORDER BY l.at", [],
            timeout: :infinity
          )

        path = free(path)
        File.write!(path <> ".part", :zlib.gzip(Enum.map_join(rows, "
", &hd/1)))
        File.rename!(path <> ".part", path)
        path
      end

    Repo.query!("DROP TABLE #{name}")
    :persistent_term.erase({__MODULE__, key})
    path
  end

  defp free(path, n \\ 1) do
    next = if n == 1, do: path, else: String.replace_suffix(path, ".ndjson.gz", ".#{n}.ndjson.gz")
    if File.exists?(next), do: free(path, n + 1), else: next
  end

  @restored_days 7

  # Months loaded back, each with the time it may be archived again.
  defp restored do
    for {name, until} <-
          (Repo.get(Dokkit.Setting, "restored") || %Dokkit.Setting{value: %{}}).value,
        {:ok, until, _} <- [DateTime.from_iso8601(until)],
        into: %{},
        do: {name, until}
  end

  @doc "The archived months in `dir`, newest first, each with whether it is loaded back now."
  def archives(dir) do
    now = DateTime.utc_now()
    back = restored()

    for file <- dir |> Path.join("logs-*.ndjson.gz") |> Path.wildcard() |> Enum.sort(:desc) do
      name = Path.basename(file, ".ndjson.gz")
      until = back[name]

      %{
        name: name,
        path: file,
        size: File.stat!(file).size,
        back_until: if(until && DateTime.compare(until, now) == :gt, do: until)
      }
    end
  end

  @doc "Loads back the archived month of that name. nil when no file of that name is listed."
  def restore_named(name) do
    with dir when is_binary(dir) <- Application.get_env(:dokkit, :archive),
         %{path: path} <- Enum.find(archives(dir), &(&1.name == name)),
         do: restore(path)
  end

  @doc """
  Loads an archived month back for a week. Lines from a machine that no longer exists are
  left out. Loading a month that is already back does nothing.
  """
  def restore(path) do
    name = Path.basename(path, ".ndjson.gz")
    now = DateTime.utc_now()
    back = restored()

    if back[name] && DateTime.compare(back[name], now) == :gt do
      0
    else
      until = DateTime.add(now, @restored_days * 86_400)
      value = Map.new(back, fn {k, v} -> {k, DateTime.to_iso8601(v)} end)

      rows = rows(path)
      save_restored(Map.put(value, name, DateTime.to_iso8601(until)))

      # The note is committed first so the hourly archive sees the month as held; it goes
      # again if the rows do not all go in.
      try do
        rows
        |> Enum.map(& &1.at)
        |> Enum.uniq_by(&{&1.year, &1.month})
        |> Enum.each(&ensure_partition/1)

        {:ok, count} =
          Repo.transaction(
            fn ->
              rows |> Enum.chunk_every(1000) |> Enum.each(&Repo.insert_all(Dokkit.Log, &1))
              length(rows)
            end,
            timeout: :infinity
          )

        count
      rescue
        e ->
          save_restored(value)
          reraise e, __STACKTRACE__
      end
    end
  end

  defp save_restored(value) do
    Repo.insert!(%Dokkit.Setting{key: "restored", value: value},
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )
  end

  defp rows(path) do
    machines = MapSet.new(Repo.all(from m in Dokkit.Machine, select: m.id))
    services = MapSet.new(Repo.all(from s in Dokkit.Service, select: s.id))

    # Postgres writes the time with or without an offset, depending on the column.
    time = fn text ->
      at =
        case DateTime.from_iso8601(text) do
          {:ok, at, _} -> at
          _ -> elem(DateTime.from_iso8601(text <> "Z"), 1)
        end

      %{at | microsecond: {elem(at.microsecond, 0), 6}}
    end

    for line <- path |> File.read!() |> :zlib.gunzip() |> String.split("\n", trim: true),
        l = Jason.decode!(line),
        l["machine_id"] in machines do
      %{
        at: time.(l["at"]),
        received_at: time.(l["received_at"]),
        level: l["level"],
        msg: l["msg"],
        fields: l["fields"],
        cut: l["cut"],
        machine_id: l["machine_id"],
        service_id: if(l["service_id"] in services, do: l["service_id"])
      }
    end
  end

  # Times far from now would each make a partition, so they are read as now.
  defp time(text, now) when is_binary(text) do
    with {:ok, at, _} <- DateTime.from_iso8601(text),
         true <- DateTime.compare(at, now) != :gt,
         true <- DateTime.diff(now, at, :day) < 365 do
      %{at | microsecond: {elem(at.microsecond, 0), 6}}
    else
      _ -> now
    end
  end

  defp time(_, now), do: now

  defp render(template, line) when is_binary(template),
    do:
      Regex.replace(~r/\{[@$]?(\w+)[^}]*\}/, template, fn whole, name ->
        if Map.has_key?(line, name), do: text(line[name]), else: whole
      end)

  defp render(_, _), do: nil

  defp text(v) when is_binary(v), do: v
  defp text(v), do: Jason.encode!(v)
end
