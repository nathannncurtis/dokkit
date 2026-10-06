defmodule Dokkit.Logs do
  @moduledoc "Log lines. Stored one partition per month; see spec/log-lines.md."
  import Ecto.Query
  alias Dokkit.{Log, Repo}

  @levels ~w(trace debug info warn error fatal)
  @clef %{
    "verbose" => "trace",
    "debug" => "debug",
    "information" => "info",
    "warning" => "warn",
    "error" => "error",
    "fatal" => "fatal"
  }
  @max_msg 64 * 1024

  def levels, do: @levels

  @doc "Turns a report line, in Dokkit's format or CLEF, into a row."
  def row(line, machine_id, service_id, received_at) do
    clef? = Map.has_key?(line, "@t") or Map.has_key?(line, "@m") or Map.has_key?(line, "@mt")
    msg = if clef?, do: line["@m"] || render(line["@mt"], line), else: line["msg"]

    if is_binary(msg) do
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

      {:ok,
       %{
         at: time(line["t"] || line["@t"] || line["at"], received_at),
         received_at: received_at,
         machine_id: machine_id,
         service_id: service_id,
         level: if(level in @levels, do: level, else: "info"),
         msg:
           if(cut, do: msg |> binary_part(0, @max_msg) |> String.replace_invalid(""), else: msg),
         fields: extra,
         cut: cut
       }}
    else
      :error
    end
  end

  def insert([]), do: 0

  def insert(rows) do
    rows |> Enum.chunk_every(2000) |> Enum.each(&Repo.insert_all(Log, &1))
    Phoenix.PubSub.broadcast(Dokkit.PubSub, "logs", :logs_changed)
    length(rows)
  end

  def subscribe, do: Phoenix.PubSub.subscribe(Dokkit.PubSub, "logs")

  @doc "Newest first. Options: q, level (that level and worse), service, machine, limit."
  def list(opts \\ []) do
    query =
      from l in Log,
        order_by: [desc: l.at, desc: l.id],
        limit: ^(opts[:limit] || 200),
        preload: [:machine, :service]

    query = if opts[:service], do: where(query, [l], l.service_id == ^opts[:service]), else: query
    query = if opts[:machine], do: where(query, [l], l.machine_id == ^opts[:machine]), else: query

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
        "CREATE TABLE IF NOT EXISTS #{name} PARTITION OF logs FOR VALUES FROM ('#{from}') TO ('#{to}')"
      )

      :persistent_term.put({__MODULE__, key}, true)
    end
  end

  @keep_months 12

  @doc """
  Writes each month older than a year to one compressed file in `dir` and drops it from the
  database. Returns the files written. A month is read whole into memory to be written.
  """
  def archive(dir, today \\ Date.utc_today()) do
    cutoff = Date.shift(Date.beginning_of_month(today), month: -@keep_months)

    held = for {name, until} <- restored(), until > DateTime.utc_now(), do: name

    months =
      Repo.query!("""
      SELECT c.relname FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_class p ON p.oid = i.inhparent
      WHERE p.relname = 'logs' ORDER BY 1
      """).rows

    for [name] <- months,
        [_, year, month] <- [Regex.run(~r/^logs_y(\d{4})m(\d{2})$/, name)],
        key = {String.to_integer(year), String.to_integer(month)},
        Date.compare(Date.new!(elem(key, 0), elem(key, 1), 1), cutoff) == :lt,
        "logs-#{year}-#{month}" not in held do
      File.mkdir_p!(dir)
      path = Path.join(dir, "logs-#{year}-#{month}.ndjson.gz")

      %{rows: rows} =
        Repo.query!("SELECT row_to_json(l)::text FROM #{name} l ORDER BY l.at", [],
          timeout: :infinity
        )

      # Written under another name first, so a half-written file is never taken for the archive.
      File.write!(path <> ".part", :zlib.gzip(Enum.map_join(rows, "\n", &hd/1)))
      File.rename!(path <> ".part", path)
      Repo.query!("DROP TABLE #{name}")
      :persistent_term.erase({__MODULE__, key})
      path
    end
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

      Repo.insert!(
        %Dokkit.Setting{key: "restored", value: Map.put(value, name, DateTime.to_iso8601(until))},
        on_conflict: {:replace, [:value, :updated_at]},
        conflict_target: :key
      )

      load(path)
    end
  end

  defp load(path) do
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

    rows =
      for line <- path |> File.read!() |> :zlib.gunzip() |> String.split("\n", trim: true),
          l = Jason.decode!(line),
          l["machine_id"] in machines do
        at = time.(l["at"])
        ensure_partition(at)

        %{
          at: at,
          received_at: time.(l["received_at"]),
          level: l["level"],
          msg: l["msg"],
          fields: l["fields"],
          cut: l["cut"],
          machine_id: l["machine_id"],
          service_id: if(l["service_id"] in services, do: l["service_id"])
        }
      end

    rows |> Enum.chunk_every(1000) |> Enum.each(&Repo.insert_all(Dokkit.Log, &1))
    length(rows)
  end

  # Times far from now would each make a partition, so they are read as now.
  defp time(text, now) when is_binary(text) do
    with {:ok, at, _} <- DateTime.from_iso8601(text),
         true <- DateTime.compare(at, now) != :gt,
         true <- DateTime.diff(now, at, :day) < 400 do
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
