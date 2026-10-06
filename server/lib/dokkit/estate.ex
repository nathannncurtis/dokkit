defmodule Dokkit.Estate do
  @moduledoc "Machines, services and jobs: what the pages read, and what the interface may change."
  import Ecto.Query
  alias Dokkit.{Check, Issue, JobRun, Keys, Machine, Repo, Service}

  @routes ~w(page push webhook none)

  def machines do
    Repo.all(
      from m in Machine,
        order_by: m.name,
        preload: [services: ^from(s in Service, order_by: s.name)]
    )
  end

  def service(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Service{} = service <- Repo.get(Service, id) do
      Repo.preload(service, [:machine, checks: from(c in Check, order_by: c.name)])
    else
      _ -> nil
    end
  end

  def open_issue(%Service{id: id}) do
    Repo.one(
      from i in Issue,
        where: i.service_id == ^id and is_nil(i.closed_at),
        order_by: [desc: i.since],
        limit: 1
    )
  end

  def runs(%Service{id: id}, limit \\ 30) do
    Repo.all(
      from r in JobRun,
        join: c in assoc(r, :check),
        where: c.service_id == ^id,
        order_by: [desc: coalesce(r.started_at, r.finished_at)],
        limit: ^limit,
        preload: [check: c]
    )
  end

  @doc "Every job with its newest run and the time of its last good one."
  def jobs do
    last =
      from r in JobRun,
        distinct: r.check_id,
        order_by: [r.check_id, desc: coalesce(r.started_at, r.finished_at)]

    good =
      from r in JobRun,
        where: r.result == :ok,
        group_by: r.check_id,
        select: %{check_id: r.check_id, at: max(r.finished_at)}

    Repo.all(
      from c in Check,
        join: s in assoc(c, :service),
        join: m in assoc(s, :machine),
        left_join: r in subquery(last),
        on: r.check_id == c.id,
        left_join: g in subquery(good),
        on: g.check_id == c.id,
        where: c.type == :job,
        order_by: [m.name, s.name, c.name],
        select: %{check: c, service: s, machine: m, last: r, good: g.at}
    )
  end

  def next_expected(check, now \\ DateTime.utc_now())

  def next_expected(%Check{config: %{"schedule" => cron}}, now) do
    with {:ok, expr} <- Crontab.CronExpression.Parser.parse(cron),
         {:ok, at} <- Crontab.Scheduler.get_next_run_date(expr, DateTime.to_naive(now)) do
      DateTime.from_naive!(at, "Etc/UTC")
    else
      _ -> nil
    end
  end

  def next_expected(_, _), do: nil

  @doc "Adds a job to watch. The key in the answer is shown once."
  def add_job(params) do
    machine = String.trim(params["machine"] || "")
    name = String.trim(params["name"] || "")
    slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

    config =
      for k <- ~w(schedule grace max_runtime),
          v = String.trim(params[k] || ""),
          v != "",
          into: %{},
          do: {k, v}

    cond do
      machine == "" or slug == "" ->
        {:error, "A job needs a name and the machine it runs on."}

      config["schedule"] &&
          match?({:error, _}, Crontab.CronExpression.Parser.parse(config["schedule"])) ->
        {:error,
         "The schedule is not a cron line Dokkit can read. Five fields, for example 0 1 * * *."}

      Enum.any?(~w(grace max_runtime), &(config[&1] && !(config[&1] =~ ~r/^\d+[smhd]$/))) ->
        {:error, "Write times as a number and a unit: 30m, 2h, 1d."}

      true ->
        Repo.transaction(fn ->
          machine =
            Repo.get_by(Machine, name: machine) ||
              Repo.insert!(%Machine{name: machine, kind: :seen})

          if Repo.get_by(Service, machine_id: machine.id, slug: slug),
            do: Repo.rollback("#{machine.name} already has something called #{name}.")

          service =
            Repo.insert!(%Service{machine_id: machine.id, slug: slug, name: name, kind: :job})

          Repo.insert!(%Check{
            service_id: service.id,
            name: slug,
            type: :job,
            fail_after: 1,
            config: config
          })

          {key, _} = Keys.mint(:app, %{service_id: service.id, label: name})
          %{service: service, key: key}
        end)
    end
  end

  def routes, do: @routes

  def set_routing(%Service{} = service, params) do
    change =
      for {field, key} <- [route_down: "down", route_degraded: "degraded"],
          do: {field, Enum.find(@routes, &(&1 == params[key]))}

    Repo.update!(Ecto.Changeset.change(service, change))
  end
end
