defmodule Dokkit.Estate do
  @moduledoc "Machines, services and jobs: what the pages read, and what the interface may change."
  import Ecto.Query
  alias Dokkit.{Check, Issue, JobRun, Keys, Machine, Repo, Service}

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

  @kinds ~w(service job dependency app)
  @types ~w(http tcp process windows-service beat stats threshold expiry custom)

  @doc """
  Takes the contents of a dokkit.toml for a machine. The file owns the service and its
  checks, so checks it no longer lists are removed. Sending the same file twice changes nothing.
  """
  def declare(machine_id, %{"service" => %{"id" => slug} = about} = doc) when is_binary(slug) do
    checks = named(List.wrap(doc["check"]))
    jobs = List.wrap(doc["job"])

    cond do
      doc["schema"] != 1 ->
        {:error, "This server reads schema 1."}

      not (slug =~ ~r/^[a-z0-9][a-z0-9._-]*$/) ->
        {:error, "service.id may hold lower-case letters, digits, dots, dashes and underscores."}

      about["kind"] not in [nil | @kinds] ->
        {:error, "service.kind is one of #{Enum.join(@kinds, ", ")}."}

      bad = Enum.find(checks, fn {_, c} -> c["type"] not in @types end) ->
        {:error,
         "A check has the type #{inspect(elem(bad, 1)["type"])}, which is not one Dokkit knows."}

      Enum.any?(jobs, &(not is_binary(&1["id"]))) ->
        {:error, "Every job needs an id."}

      true ->
        Repo.transaction(fn ->
          service = Repo.get_by(Service, machine_id: machine_id, slug: slug)
          alert = (is_map(doc["alert"]) && doc["alert"]) || %{}

          attrs = [
            name: about["name"] || slug,
            kind: String.to_existing_atom(about["kind"] || "service"),
            environment: about["environment"] || "production",
            declared: doc
          ]

          service =
            if service do
              Repo.update!(Ecto.Changeset.change(service, attrs))
            else
              seed = [route_down: route(alert["down"]), route_degraded: route(alert["degraded"])]

              Repo.insert!(
                struct!(Service, [machine_id: machine_id, slug: slug] ++ attrs ++ seed)
              )
            end

          wanted =
            for(
              {name, c} <- checks,
              do: {name, c["type"], Map.drop(c, ~w(type name fail_after)), c["fail_after"] || 3}
            ) ++
              for(j <- jobs, do: {j["id"], "job", Map.drop(j, ["id"]), 1})

          names = for {name, _, _, _} <- wanted, do: name

          Repo.delete_all(
            from c in Check,
              where: c.service_id == ^service.id and c.source == :file and c.name not in ^names
          )

          for {name, type, config, fail_after} <- wanted do
            type =
              if type == "job",
                do: :job,
                else: Enum.find(Ecto.Enum.values(Check, :type), &(to_string(&1) == type))

            case Repo.get_by(Check, service_id: service.id, name: name) do
              nil ->
                Repo.insert!(%Check{
                  service_id: service.id,
                  name: name,
                  type: type,
                  source: :file,
                  config: config,
                  fail_after: fail_after
                })

              check ->
                Repo.update!(
                  Ecto.Changeset.change(check,
                    type: type,
                    source: :file,
                    config: config,
                    fail_after: fail_after
                  )
                )
            end
          end

          Dokkit.Tasks.declared(service, doc["task"])
          service
        end)
    end
  end

  def declare(_, _), do: {:error, "A declaration needs [service] with an id."}

  # A check is called by its name, or by its type when the file gives none.
  defp named(checks) do
    checks
    |> Enum.filter(&is_map/1)
    |> Enum.reduce([], fn c, acc ->
      base = (is_binary(c["name"]) && c["name"]) || to_string(c["type"])

      taken =
        Enum.count(acc, fn {name, _} -> name == base or String.starts_with?(name, base <> "-") end)

      [{if(taken == 0, do: base, else: "#{base}-#{taken + 1}"), c} | acc]
    end)
    |> Enum.reverse()
  end

  defp route(value),
    do: Enum.find_value(Dokkit.Alerts.channels(), fn {_, v} -> v == value && v end)

  @doc "Starts or stops watching. Stopping closes what is open and forgets what the checks said."
  def set_watched(%Service{} = service, watched) when is_boolean(watched) do
    unless watched do
      now = DateTime.utc_now()

      for issue <-
            Repo.all(
              from i in Dokkit.Issue, where: i.service_id == ^service.id and is_nil(i.closed_at)
            ) do
        Repo.update!(Ecto.Changeset.change(issue, closed_at: now))
        Dokkit.Alerts.closing(issue)
      end

      Repo.update_all(from(c in Check, where: c.service_id == ^service.id),
        set: [state: :unknown, fails: 0, passes: 0, note: nil]
      )
    end

    change = if watched, do: [watched: true], else: [watched: false, state: :unknown, note: nil]
    service = Repo.update!(Ecto.Changeset.change(service, change))
    Dokkit.Issues.changed()
    service
  end

  @doc "Marks a version as held on purpose, so being behind is not news. nil lets go."
  def set_hold(%Service{} = service, version),
    do:
      Repo.update!(
        Ecto.Changeset.change(service,
          held: (is_binary(version) && version != "" && version) || nil
        )
      )

  @doc "Allows the installed program to start this service's Windows service when it has stopped."
  def set_restart(%Service{} = service, allow),
    do: Repo.update!(Ecto.Changeset.change(service, restart: allow == true))

  @doc "Keeps the message text of this service's errors from now on, or stops keeping it."
  def set_keep_messages(%Service{} = service, keep),
    do: Repo.update!(Ecto.Changeset.change(service, keep_messages: keep == true))

  @runs ~w(http tcp process windows-service)

  @doc """
  Replaces the checks added in the interface. Checks that came from a file are left alone:
  they change in the file.
  """
  def set_checks(%Service{} = service, list) when is_list(list) do
    wanted =
      for %{"name" => name, "type" => type} = c <- list,
          is_binary(name) and name != "" and type in @runs,
          do:
            {name, String.to_existing_atom(type), (is_map(c["config"]) && c["config"]) || %{},
             c["fail_after"]}

    names = Enum.map(wanted, &elem(&1, 0))

    mine =
      from c in Check,
        where:
          c.service_id == ^service.id and c.source != :file and
            c.type in ^Enum.map(@runs, &String.to_existing_atom/1)

    from_file =
      Repo.all(
        from c in Check, where: c.service_id == ^service.id and c.source == :file, select: c.name
      )

    cond do
      length(wanted) != length(list) ->
        {:error, "Each check needs a name and a type of http, tcp, process or windows-service."}

      names != Enum.uniq(names) or Enum.any?(names, &(&1 in from_file)) ->
        {:error, "Two checks of a service cannot share a name."}

      true ->
        Repo.delete_all(from c in mine, where: c.name not in ^names)

        for {name, type, config, fail_after} <- wanted do
          check =
            Repo.get_by(Check, service_id: service.id, name: name) ||
              %Check{service_id: service.id, name: name}

          after_n =
            if is_integer(fail_after) and fail_after in 1..100,
              do: fail_after,
              else: check.fail_after

          Repo.insert_or_update!(
            Ecto.Changeset.change(check, type: type, config: config, fail_after: after_n)
          )
        end

        Dokkit.Issues.changed(false)
        {:ok, service(service.id)}
    end
  end

  def set_checks(_, _), do: {:error, "Needs checks, a list."}

  def set_routing(%Service{} = service, params) do
    change =
      for {field, key} <- [route_down: "down", route_degraded: "degraded"],
          do: {field, route(params[key])}

    Repo.update!(Ecto.Changeset.change(service, change))
  end
end
