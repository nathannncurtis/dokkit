defmodule Dokkit.Found do
  @moduledoc """
  What a scan found on a machine and nobody has decided about yet. Watching one makes a
  service with one check, which `dokkit watch` on that machine then runs; a found job waits
  for its first report instead.
  """
  import Ecto.Query
  alias Dokkit.{Check, Finding, Repo, Service, WorkRun}

  @max 2000
  @runs ~w(http tcp process windows-service systemd)a
  @from_record ~w(task-scheduler systemd-timer)

  @doc "Takes a proposal file. Only what can be watched is kept: running services, listening ports, scheduled jobs, containers that publish a port and sites with an address."
  def propose(machine_id, %{"found" => %{} = found} = body) do
    watched =
      MapSet.new(checks(machine_id), fn c ->
        {c.type, to_string(c.config["name"] || c.config["port"] || c.config["url"])}
      end)

    taken =
      MapSet.new(Repo.all(from s in Service, where: s.machine_id == ^machine_id, select: s.slug))

    type = %{"windows" => :"windows-service", "linux" => :systemd}[body["os"]]

    services =
      for %{"name" => name, "state" => "running"} = s <- List.wrap(found["services"]),
          type,
          is_binary(name),
          {type, name} not in watched,
          do:
            {"service", name,
             %{
               "label" => text(s["display"]) || name,
               "saw" => "Running",
               "type" => to_string(type)
             }}

    ports =
      for %{"port" => port} = p <- List.wrap(found["ports"]),
          {n, ""} <- [Integer.parse(to_string(port))],
          n in 1..65535,
          {:tcp, to_string(n)} not in watched,
          do:
            {"port", to_string(n),
             %{"label" => "Port #{n}", "saw" => text(p["program"]) || "Listening"}}

    containers =
      for %{"name" => name, "port" => port} = c <- List.wrap(found["containers"]),
          is_binary(name),
          slug(name) != "",
          ("container-" <> slug(name)) not in taken,
          {n, ""} <- [Integer.parse(to_string(port))],
          n in 1..65535,
          {:tcp, to_string(n)} not in watched,
          do:
            {"container", slug(name),
             %{
               "label" => text(name),
               "saw" => "Container " <> (text(c["image"]) || "") <> ", port #{n}",
               "port" => n
             }}

    sites =
      for %{"name" => name, "url" => url} = s <- List.wrap(found["sites"]),
          is_binary(name),
          slug(name) != "",
          is_binary(url) and url =~ ~r{^https?://[^\s]+$},
          s["state"] in [nil, "started"],
          {:http, url} not in watched,
          ("site-" <> slug(name)) not in taken,
          do:
            {"site", slug(name),
             %{
               "label" => text(name),
               "saw" => "#{String.upcase(to_string(s["server"] || "web server"))} site at #{url}",
               "url" => url
             }}

    notes =
      for n <- List.wrap(body["notes"]), is_binary(n), do: String.slice(n, 0, 400)

    jobs =
      for %{"name" => name} = j <- List.wrap(found["jobs"]),
          is_binary(name),
          slug(name) != "",
          slug(name) not in taken,
          do: {"job", slug(name), job_detail(name, j, Enum.take(notes, 6))}

    now = DateTime.utc_now()

    # One row for each kind and key: a scan can list the same one twice.
    rows =
      for {kind, key, detail} <-
            (services ++ ports ++ containers ++ sites ++ jobs)
            |> Enum.uniq_by(fn {kind, key, _} -> {kind, key} end)
            |> Enum.take(@max) do
        %{
          id: Ecto.UUID.generate(),
          machine_id: machine_id,
          kind: kind,
          key: key,
          detail: detail,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Finding, rows,
      on_conflict: {:replace, [:detail, :updated_at]},
      conflict_target: [:machine_id, :kind, :key]
    )

    Dokkit.Issues.changed(false)
    {:ok, Repo.aggregate(from(f in waiting(), where: f.machine_id == ^machine_id), :count)}
  end

  def propose(_, _), do: :error

  defp job_detail(name, j, limits) do
    schedule = if valid_schedule?(j["schedule"]), do: j["schedule"]

    note =
      cond do
        schedule -> text(j["schedule_note"])
        text(j["schedule_note"]) -> text(j["schedule_note"])
        true -> "Its schedule could not be read."
      end

    source = text(j["source"])
    record? = j["record"] == "record" and source in @from_record

    detail =
      for {k, v} <- [
            {"schedule", schedule},
            {"schedule_note", note},
            {"last_run", text(j["last_run"])},
            {"last_result", text(j["last_result"])},
            {"command", text(j["command"])},
            {"user", text(j["user"])},
            {"where", text(j["where"])},
            {"description", text(j["description"])},
            {"source", source},
            {"unit", text(j["unit"])}
          ],
          v,
          into: %{},
          do: {k, v}

    Map.merge(detail, %{
      "label" => String.slice(name, 0, 200),
      "saw" => schedule || "No schedule",
      "record" => if(record?, do: "record", else: "wrapper"),
      "limits" => limits
    })
  end

  defp valid_schedule?(cron) when is_binary(cron) do
    with {:ok, expr} <- Crontab.CronExpression.Parser.parse(cron),
         {:ok, _} <- Crontab.Scheduler.get_next_run_date(expr, NaiveDateTime.utc_now()) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_schedule?(_), do: false

  defp text(value), do: is_binary(value) && value != "" && String.slice(value, 0, 300)

  defp waiting, do: from(f in Finding, where: not f.dismissed)

  def list,
    do: Repo.all(from f in waiting(), order_by: [f.kind, f.key], preload: :machine)

  def count, do: Repo.aggregate(waiting(), :count)

  def dismiss(ids) do
    Repo.update_all(from(f in Finding, where: f.id in ^cast(ids)), set: [dismissed: true])
    Dokkit.Issues.changed(false)
  end

  @doc "Starts watching each found thing: a service of its machine with one check."
  def watch(ids) do
    for f <- Repo.all(from f in Finding, where: f.id in ^cast(ids)) do
      {slug, name, kind, type, check, config} =
        case f.kind do
          "service" ->
            type = f.detail["type"] || "windows-service"

            {slug(f.key), f.detail["label"], :service, String.to_existing_atom(type), type,
             %{"name" => f.key}}

          "port" ->
            {"port-" <> f.key, "#{f.detail["saw"]} on port #{f.key}", :service, :tcp, "tcp",
             %{"port" => String.to_integer(f.key)}}

          "container" ->
            {"container-" <> f.key, f.detail["label"], :service, :tcp, "tcp",
             %{"port" => f.detail["port"]}}

          "site" ->
            {"site-" <> f.key, f.detail["label"], :service, :http, "http",
             %{"url" => f.detail["url"]}}

          "job" ->
            {f.key, f.detail["label"], :job, :job, f.key, job_config(f.detail)}
        end

      service =
        Repo.get_by(Service, machine_id: f.machine_id, slug: slug) ||
          Repo.insert!(%Service{
            machine_id: f.machine_id,
            slug: slug,
            name: name,
            kind: kind
          })

      Repo.get_by(Check, service_id: service.id, name: check) ||
        Repo.insert!(%Check{
          service_id: service.id,
          name: check,
          type: type,
          config: config,
          fail_after: if(type == :job, do: 1, else: 3)
        })

      Repo.delete!(f)
    end

    Dokkit.Issues.changed(false)
  end

  # A found job cannot be watched until something reports its runs, so it waits for the first.
  defp job_config(detail) do
    base = %{"waiting" => true}
    base = if detail["schedule"], do: Map.put(base, "schedule", detail["schedule"]), else: base

    if detail["record"] == "record" and detail["source"] in @from_record and detail["unit"],
      do: Map.merge(base, %{"record" => detail["source"], "unit" => detail["unit"]}),
      else: base
  end

  @doc "The jobs of a machine whose runs the program reads from the machine's own record."
  def records(machine_id) do
    for c <-
          Repo.all(
            from c in Check,
              join: s in assoc(c, :service),
              where: s.machine_id == ^machine_id and s.watched and c.type == :job,
              select: %{service: s.slug, name: c.name, config: c.config}
          ),
        c.config["record"] in @from_record and is_binary(c.config["unit"]) do
      %{service: c.service, name: c.name, source: c.config["record"], unit: c.config["unit"]}
    end
  end

  @doc "The latest look-again run of each machine, by machine id."
  def scans do
    Repo.all(
      from r in WorkRun,
        where: r.name == "dokkit:scan",
        distinct: r.machine_id,
        order_by: [asc: r.machine_id, desc: r.inserted_at]
    )
    |> Map.new(&{&1.machine_id, &1})
  end

  def slug(name) do
    name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
  end

  defp cast(ids), do: for(id <- List.wrap(ids), {:ok, id} <- [Ecto.UUID.cast(id)], do: id)

  @doc "The checks of a machine that no file declares and the program can run."
  def checks(machine_id) do
    Repo.all(
      from c in Check,
        join: s in assoc(c, :service),
        where:
          s.machine_id == ^machine_id and s.watched and c.source != :file and c.type in ^@runs,
        select: %{
          service: s.slug,
          name: c.name,
          type: c.type,
          config: c.config,
          restart: s.restart and c.type in [:"windows-service", :systemd]
        }
    )
  end
end
