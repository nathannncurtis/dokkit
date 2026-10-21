defmodule Dokkit.Errors do
  @moduledoc """
  Errors an app reports, grouped by type and the app's own frames.
  Message text is kept only for a service set to keep it.
  """
  import Ecto.Query
  alias Dokkit.{Check, ErrorEvent, ErrorGroup, Issues, Repo, Service, Values}

  @max_frames 100
  @bursts :dokkit_error_bursts

  def init, do: :ets.new(@bursts, [:named_table, :public, :set])

  @doc "Takes one report for a service."
  def report(%Service{} = service, %{"type" => type} = report) when is_binary(type) do
    type = String.slice(type, 0, 200)
    frames = frames(report["frames"])
    own = Enum.filter(frames, & &1["own"])
    # Line numbers stay out of the group, so an edit above the line does not split it.
    basis = for f <- if(own == [], do: frames, else: own), do: [f["file"], f["function"]]

    fingerprint =
      :crypto.hash(:sha256, :erlang.term_to_binary({type, basis})) |> Base.encode16(case: :lower)

    top = List.last(own) || List.last(frames)
    now = DateTime.utc_now()
    at = at(report["at"], now)

    seen = [
      count: 1,
      last_seen: at,
      release: text(report["release"]),
      host: text(report["host"]),
      handled: report["handled"] == true
    ]

    {_, [group]} =
      Repo.insert_all(
        ErrorGroup,
        [
          [
            id: Ecto.UUID.generate(),
            service_id: service.id,
            fingerprint: fingerprint,
            type: type,
            top: top && "#{top["file"]} in #{top["function"]}",
            first_seen: at
          ] ++ seen
        ],
        on_conflict: [inc: [count: 1], set: Keyword.delete(seen, :count)],
        conflict_target: [:service_id, :fingerprint],
        returning: [:id, :count]
      )

    # A group keeps its first reports and then one in so many, so a crash loop cannot fill the table.
    if group.count <= Values.quick("errors_first") or
         rem(group.count, Values.quick("errors_every")) == 0 do
      Repo.insert!(%ErrorEvent{
        group_id: group.id,
        at: at,
        release: seen[:release],
        host: seen[:host],
        handled: seen[:handled],
        frames: frames,
        tags: tags(report["tags"]),
        message: if(service.keep_messages, do: message(report["message"]))
      })
    end

    burst(service, at)
    Dokkit.Issues.changed(false)
    :ok
  end

  def report(_, _), do: {:error, "bad_report", "An error needs a type."}

  defp minute, do: div(System.os_time(:second), 60)

  defp burst(service, at) do
    v = Values.all()

    if v["error_alert_on"] do
      key = {service.id, minute()}
      :ets.update_counter(@bursts, key, 1, {key, 0})
      n = recent(service.id, v["error_alert_minutes"])

      if n >= v["error_alert_count"],
        do:
          Issues.record(burst_check(service), :degraded,
            at: at,
            value: n / 1,
            title: "#{service.name} is raising errors",
            note: "#{n} errors in the last #{v["error_alert_minutes"]} minutes."
          )
    end
  end

  defp recent(service_id, minutes) do
    now = minute()

    Enum.sum(
      for m <- (now - minutes + 1)..now,
          [{_, n}] <- [:ets.lookup(@bursts, {service_id, m})],
          do: n
    )
  end

  defp burst_check(service) do
    Repo.get_by(Check, service_id: service.id, name: "errors") ||
      Repo.insert!(%Check{service_id: service.id, name: "errors", type: :custom, fail_after: 1})
  end

  @doc "Each minute: a burst of errors that has calmed down, or whose alert is switched off, closes."
  def calm do
    v = Values.all()
    old = minute() - 1440
    :ets.select_delete(@bursts, [{{{:_, :"$1"}, :_}, [{:<, :"$1", old}], [true]}])

    for c <-
          Repo.all(
            from c in Check, where: c.name == "errors" and c.type == :custom and c.state != :ok
          ),
        not v["error_alert_on"] or
          recent(c.service_id, v["error_alert_minutes"]) < v["error_alert_count"],
        do: Issues.record(c, :ok)
  end

  defp frames(list) when is_list(list) do
    for %{} = f <- Enum.take(list, -@max_frames) do
      %{
        "file" => text(f["file"]),
        "function" => text(f["function"]),
        "line" => is_integer(f["line"]) && f["line"],
        "own" => f["own"] == true
      }
    end
  end

  defp frames(_), do: []

  defp tags(%{} = tags) do
    for {k, v} <- Enum.take(tags, 20), is_binary(k), is_binary(v) or is_number(v), into: %{} do
      {String.slice(k, 0, 50), v |> to_string() |> String.slice(0, 200)}
    end
  end

  defp tags(_), do: %{}

  defp message(value), do: if(is_binary(value), do: String.slice(value, 0, 2000))

  defp text(value), do: if(is_binary(value), do: String.slice(value, 0, 300))

  defp at(text, now) do
    with true <- is_binary(text),
         {:ok, at, _} <- DateTime.from_iso8601(text),
         true <- DateTime.compare(at, now) != :gt do
      %{at | microsecond: {elem(at.microsecond, 0), 6}}
    else
      _ -> now
    end
  end

  def list(opts \\ []) do
    query = from g in ErrorGroup, order_by: [desc: g.last_seen], preload: [service: :machine]
    query = if id = opts[:service], do: where(query, [g], g.service_id == ^id), else: query
    query = if t = opts[:since], do: where(query, [g], g.first_seen >= ^t), else: query
    Repo.all(limit(query, ^(opts[:limit] || 200)))
  end

  @doc "One group with its latest report. nil when there is none."
  def get(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %ErrorGroup{} = group <- Repo.get(ErrorGroup, id) do
      latest =
        Repo.one(from e in ErrorEvent, where: e.group_id == ^id, order_by: [desc: e.at], limit: 1)

      %{group: Repo.preload(group, service: :machine), latest: latest}
    else
      _ -> nil
    end
  end
end
