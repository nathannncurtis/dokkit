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
