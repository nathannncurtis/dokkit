defmodule Dokkit.Processes do
  @moduledoc """
  A machine's process list: the newest full list, and 24 hours of the top 10 by memory and by
  processor. See spec/api.md, Intake and Read.
  """
  import Ecto.Query
  alias Dokkit.{Machine, ProcessList, ProcessTop, Repo}

  @max_items 10_000
  @max_text 260
  @top 10
  @keep_hours 24
  @fresh_seconds 300
  @default_limit 50
  @snapshot_metrics ~w(memory.used_percent cpu.percent)
  @stopped ~w(windows-service systemd process)a

  @doc "Stores a `processes` line. A bad item is dropped; a line older than the stored list is ignored."
  def record(machine_id, line, at) do
    with total when is_integer(total) and total >= 0 <- whole(line["total_memory_bytes"]),
         items when is_list(items) <- line["items"] do
      items = items |> Enum.take(@max_items) |> Enum.flat_map(&item/1)

      {stored, _} =
        Repo.insert_all(
          ProcessList,
          [%{machine_id: machine_id, at: at, total_memory_bytes: total, items: items}],
          conflict_target: :machine_id,
          on_conflict:
            from(p in ProcessList,
              where: p.at <= ^at,
              update: [set: [at: ^at, total_memory_bytes: ^total, items: ^items]]
            )
        )

      if stored == 1 do
        Repo.insert_all(ProcessTop, [
          %{machine_id: machine_id, kind: "memory", at: at, items: top(items, :memory)},
          %{machine_id: machine_id, kind: "cpu", at: at, items: top(items, :cpu)}
        ])
      end

      :ok
    else
      _ -> {:error, "bad_line", "Needs total_memory_bytes and a list of items."}
    end
  end

  defp item(%{"pid" => pid, "ppid" => ppid, "name" => name, "memory_bytes" => memory} = i)
       when is_integer(pid) and pid >= 0 and is_integer(ppid) and ppid >= 0 and
              is_binary(name) and is_number(memory) and memory >= 0 do
    cpu = i["cpu_percent"]

    if is_nil(cpu) or (is_number(cpu) and cpu >= 0 and cpu <= 100) do
      [
        %{
          "pid" => pid,
          "ppid" => ppid,
          "name" => cut(name),
          "path" => text(i["path"]),
          "memory_bytes" => trunc(memory),
          "cpu_percent" => cpu && cpu / 1,
          "session" => if(is_integer(i["session"]), do: i["session"]),
          "user" => text(i["user"])
        }
      ]
    else
      []
    end
  end

  defp item(_), do: []

  defp whole(n) when is_integer(n), do: n
  defp whole(n) when is_float(n), do: trunc(n)
  defp whole(_), do: nil

  defp text(value), do: if(is_binary(value), do: cut(value))
  defp cut(text), do: String.slice(text, 0, @max_text)

  defp top(items, :memory),
    do: items |> Enum.sort_by(& &1["memory_bytes"], :desc) |> short()

  defp top(items, :cpu),
    do: items |> Enum.sort_by(&(&1["cpu_percent"] || -1), :desc) |> short()

  defp short(items),
    do: items |> Enum.take(@top) |> Enum.map(&Map.take(&1, ~w(pid name memory_bytes cpu_percent)))

  @doc "Drops top lists older than 24 hours."
  def prune(now),
    do:
      Repo.delete_all(from t in ProcessTop, where: t.at < ^DateTime.add(now, -@keep_hours * 3600))

  @doc """
  What to keep with an issue that is opening: the machine's newest top lists, when they are
  under 5 minutes old and the issue is about its memory or processor or a stopped service.
  """
  def snapshot(check, machine_id, state, now) do
    if about?(check, state), do: newest(machine_id, now)
  end

  defp about?(%{type: :threshold, config: %{"metric" => metric}}, _),
    do: metric in @snapshot_metrics

  defp about?(%{type: type}, state), do: type in @stopped and state == :down

  defp newest(machine_id, now) do
    rows =
      Repo.all(
        from t in ProcessTop,
          where: t.machine_id == ^machine_id and t.at > ^DateTime.add(now, -@fresh_seconds),
          order_by: [desc: t.at],
          limit: 2
      )

    with %{} = memory <- Enum.find(rows, &(&1.kind == "memory")),
         %{} = cpu <- Enum.find(rows, &(&1.kind == "cpu")) do
      %{
        "at" => DateTime.to_iso8601(memory.at),
        "top_memory" => memory.items,
        "top_cpu" => cpu.items
      }
    end
  end

  @doc "A machine by id or by name; nil when there is none."
  def machine(id_or_name) when is_binary(id_or_name) do
    case Ecto.UUID.cast(id_or_name) do
      {:ok, id} -> Repo.get(Machine, id)
      :error -> Repo.get_by(Machine, name: id_or_name)
    end
  end

  def machine(_), do: nil

  @doc "The newest list: `sort` memory or cpu, `q`, `pid`, `limit`."
  def list(%Machine{id: id}, params) do
    case Repo.get(ProcessList, id) do
      nil ->
        %{at: nil, total_memory_bytes: nil, items: [], count: 0}

      %ProcessList{} = list ->
        items = list.items |> narrow(params) |> sorted(params["sort"])

        %{
          at: list.at,
          total_memory_bytes: list.total_memory_bytes,
          items:
            items
            |> Enum.take(limit(params["limit"]))
            |> Enum.map(&Map.put(&1, "memory_percent", percent(&1, list.total_memory_bytes))),
          count: length(items)
        }
    end
  end

  defp narrow(items, params) do
    items =
      case {params["pid"], int(params["pid"])} do
        {pid, _} when pid in [nil, ""] -> items
        {_, nil} -> []
        {_, pid} -> Enum.filter(items, &(&1["pid"] == pid))
      end

    case params["q"] do
      q when is_binary(q) and q != "" ->
        q = String.downcase(q)

        Enum.filter(items, fn i ->
          String.contains?(String.downcase(i["name"]), q) or
            String.contains?(String.downcase(i["path"] || ""), q)
        end)

      _ ->
        items
    end
  end

  defp sorted(items, "cpu"), do: Enum.sort_by(items, &(&1["cpu_percent"] || -1), :desc)
  defp sorted(items, _), do: Enum.sort_by(items, & &1["memory_bytes"], :desc)

  defp limit(value) do
    case int(value) do
      n when is_integer(n) and n >= 1 -> min(n, @max_items)
      _ -> @default_limit
    end
  end

  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: trunc(n)

  defp int(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp int(_), do: nil

  defp percent(_, 0), do: nil
  defp percent(%{"memory_bytes" => bytes}, total), do: Float.round(bytes / total * 100, 1)

  @doc "The stored top lists of one kind between two times, oldest first."
  def history(%Machine{id: id}, kind, from, to) do
    for t <-
          Repo.all(
            from t in ProcessTop,
              where: t.machine_id == ^id and t.kind == ^kind and t.at >= ^from and t.at <= ^to,
              order_by: t.at
          ),
        do: %{at: t.at, items: t.items}
  end
end
