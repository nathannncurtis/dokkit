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

  def machine(id) do
    with {:ok, id} <- Ecto.UUID.cast(id), do: Repo.get(Machine, id)
  end

  @doc "The row that stands for a machine itself, with its checks, or nil."
  def machine_service(machine_id) do
    Repo.one(
      from s in Service,
        where: s.machine_id == ^machine_id and s.slug == "machine",
        preload: [checks: ^from(c in Check, order_by: c.name)]
    )
  end

  def machine_services(machine_id),
    do: Repo.all(from s in Service, where: s.machine_id == ^machine_id, order_by: s.name)

  @doc "When a service last reported: its newest check or stats, or nil."
  def last_reported(%Service{id: id, stats_at: stats_at}) do
    checked = Repo.all(from c in Check, where: c.service_id == ^id, select: c.checked_at)

    [stats_at | checked]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
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

  def runs(%Service{id: id}, limit \\ 30, opts \\ []) do
    query =
      from r in JobRun,
        join: c in assoc(r, :check),
        where: c.service_id == ^id,
        order_by: [desc: coalesce(r.started_at, r.finished_at), desc: r.id],
        limit: ^limit,
        preload: [check: c]

    query =
      if opts[:from],
        do: where(query, [r], coalesce(r.started_at, r.finished_at) >= ^opts[:from]),
        else: query

    query =
      if opts[:to],
        do: where(query, [r], coalesce(r.started_at, r.finished_at) <= ^opts[:to]),
        else: query

    query =
      case opts[:result] do
        result when result in ~w(running ok fail) ->
          where(query, [r], r.result == ^String.to_existing_atom(result))

        _ ->
          query
      end

    query =
      case opts[:after] do
        {at, rid} ->
          where(
            query,
            [r],
            coalesce(r.started_at, r.finished_at) < ^at or
              (coalesce(r.started_at, r.finished_at) == ^at and r.id < ^rid)
          )

        _ ->
          query
      end

    Repo.all(query)
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
    with {:ok, at} <- next_run(cron, now), do: DateTime.from_naive!(at, "Etc/UTC")
  end

  def next_expected(_, _), do: nil

  # Schedules are read as UTC. @reboot and the like parse but have no next run.
  defp next_run(cron, now) when is_binary(cron) do
    with {:ok, expr} <- Crontab.CronExpression.Parser.parse(cron),
         {:ok, at} <- Crontab.Scheduler.get_next_run_date(expr, DateTime.to_naive(now)) do
      {:ok, at}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp next_run(_, _), do: nil

  @duration ~r/^\d+[smhd]$/
  @duration_error "Write times as a number and a unit: 30m, 2h, 1d."

  @doc "Adds a job to watch. The key in the answer is shown once."
  def add_job(params) do
    machine = String.trim(params["machine"] || "")
    name = String.trim(params["name"] || "")
    slug = Dokkit.Found.slug(name)

    config =
      for k <- ~w(schedule grace max_runtime),
          v = String.trim(params[k] || ""),
          v != "",
          into: %{},
          do: {k, v}

    cond do
      machine == "" or slug == "" ->
        {:error, "A job needs a name and the machine it runs on."}

      config["schedule"] && is_nil(next_run(config["schedule"], DateTime.utc_now())) ->
        {:error,
         "The schedule is not a cron line Dokkit can read. Five fields, for example 0 1 * * *."}

      Enum.any?(~w(grace max_runtime), &(config[&1] && !(config[&1] =~ @duration))) ->
        {:error, @duration_error}

      true ->
        with {:ok, _} = added <-
               Repo.transaction(fn ->
                 machine =
                   Repo.get_by(Machine, name: machine) ||
                     Repo.insert!(%Machine{name: machine, kind: :seen})

                 if Repo.get_by(Service, machine_id: machine.id, slug: slug),
                   do: Repo.rollback("#{machine.name} already has something called #{name}.")

                 service =
                   Repo.insert!(%Service{
                     machine_id: machine.id,
                     slug: slug,
                     name: name,
                     kind: :job
                   })

                 Repo.insert!(%Check{
                   service_id: service.id,
                   name: slug,
                   type: :job,
                   fail_after: 1,
                   config: config
                 })

                 {key, _} = Keys.mint(:app, %{service_id: service.id, label: name})
                 %{service: service, key: key}
               end) do
          Dokkit.Issues.changed(false)
          added
        end
    end
  end

  @doc """
  Adds an app that runs on many machines, such as a desktop program, and makes its key. It
  belongs to no one machine: each PC it reports from shows up as it is seen.
  """
  def add_app(params) do
    name = String.trim(params["name"] || "")
    slug = Dokkit.Found.slug(name)

    if slug == "" do
      {:error, "An app needs a name."}
    else
      Repo.transaction(fn ->
        home =
          Repo.get_by(Machine, name: "Apps") || Repo.insert!(%Machine{name: "Apps", kind: :group})

        if Repo.get_by(Service, machine_id: home.id, slug: slug),
          do: Repo.rollback("There is already an app called #{name}.")

        service = Repo.insert!(%Service{machine_id: home.id, slug: slug, name: name, kind: :app})
        {key, _} = Keys.mint(:app, %{service_id: service.id, label: name})
        %{service: service, key: key}
      end)
    end
  end

  @app_checks 100
  @doc """
  Adds something outside that is depended on. Nothing here can reach it, so its check is
  assigned to an enrolled machine and run by that machine's program; without a check it
  belongs to the group machine Outside.
  """
  def add_dependency(params) do
    name = String.trim(params["name"] || "")
    slug = Dokkit.Found.slug(name)
    machine = String.trim(params["machine"] || "")

    with true <- slug != "" or {:error, "A dependency needs a name."},
         {:ok, check} <- dependency_check(params["check"]),
         {:ok, home} <- dependency_home(machine, check) do
      Repo.transaction(fn ->
        if Repo.get_by(Service, machine_id: home.id, slug: slug),
          do: Repo.rollback("#{home.name} already has something called #{name}.")

        service =
          Repo.insert!(%Service{machine_id: home.id, slug: slug, name: name, kind: :dependency})

        with true <- check != nil,
             {:error, why} <- set_checks(service, [check]) do
          Repo.rollback(why)
        end

        service.id
      end)
    end
  end

  defp dependency_check(nil), do: {:ok, nil}

  defp dependency_check(%{"type" => "http", "url" => url} = c) when is_binary(url) do
    if url =~ ~r{^https?://[^\s/]+}i,
      do: {:ok, %{"name" => c["name"] || "http", "type" => "http", "config" => %{"url" => url}}},
      else: {:error, "An http check needs a url that starts with http:// or https://."}
  end

  defp dependency_check(%{"type" => "tcp", "address" => address} = c) when is_binary(address) do
    case Regex.run(~r/^(\S+):(\d{1,5})$/, address) do
      [_, host, port] when port != "0" ->
        {:ok,
         %{
           "name" => c["name"] || "tcp",
           "type" => "tcp",
           "config" => %{"host" => host, "port" => String.to_integer(port)}
         }}

      _ ->
        {:error, "A tcp check needs an address as host:port."}
    end
  end

  defp dependency_check(_),
    do: {:error, "check is an http check with a url, or a tcp check with an address (host:port)."}

  defp dependency_home("", nil) do
    {:ok,
     Repo.get_by(Machine, name: "Outside") ||
       Repo.insert!(%Machine{name: "Outside", kind: :group})}
  end

  defp dependency_home("", _), do: {:error, "A check runs on a machine: say which with machine."}

  defp dependency_home(name, check) do
    machine =
      Repo.get_by(Machine, name: name) ||
        case Ecto.UUID.cast(name) do
          {:ok, id} -> Repo.get(Machine, id)
          _ -> nil
        end

    cond do
      machine == nil ->
        {:error, "There is no machine called #{name}."}

      check && machine.kind != :enrolled ->
        {:error, "#{machine.name} runs no dokkit to run the check."}

      true ->
        {:ok, machine}
    end
  end

  @kinds ~w(service job dependency app)
  @types ~w(http tcp process windows-service systemd beat stats threshold expiry custom)

  @doc """
  Takes the contents of a dokkit.toml for a machine. The file owns the service and its
  checks, so checks it no longer lists are removed. Sending the same file twice changes nothing.
  An app key declares only the service it belongs to. It keeps its machine and kind, may set a
  name and environment, and may list jobs (schedule, grace, max_runtime) and checks of type beat
  or custom, which only wait for reports. Any other check type is refused; other sections are dropped.
  """
  def declare(machine_id, %{"service" => %{"id" => slug} = about} = doc)
      when is_binary(machine_id) and is_binary(slug) do
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

      Enum.any?(jobs, &(not is_map(&1) or not is_binary(&1["id"]))) ->
        {:error, "Every job needs an id."}

      Enum.any?(jobs, &(&1["schedule"] && is_nil(next_run(&1["schedule"], DateTime.utc_now())))) ->
        {:error, "A job's schedule is not a cron line Dokkit can read."}

      Enum.any?(
        List.wrap(doc["check"]),
        &(is_map(&1) and
              not (is_nil(&1["fail_after"]) or &1["fail_after"] in 1..100//1))
      ) ->
        {:error, "fail_after is a whole number from 1 to 100."}

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
              do:
                {name, c["type"], own_fail_after(Map.drop(c, config_drop(c["type"])), c),
                 c["fail_after"] || 3}
            ) ++
              for(j <- jobs, do: {j["id"], "job", Map.drop(j, ["id"]), 1})

          names = for {name, _, _, _} <- wanted, do: name

          drop_checks(
            from(c in Check,
              where: c.service_id == ^service.id and c.source == :file and c.name not in ^names
            ),
            service
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

          service
        end)
    end
  end

  @app_check_types ~w(beat custom)
  @app_job_fields ~w(id schedule grace max_runtime)

  def declare(%Service{} = own, %{"service" => %{"id" => slug} = about} = doc) do
    checks = List.wrap(doc["check"])
    jobs = List.wrap(doc["job"])

    cond do
      slug != own.slug ->
        {:error, "This key belongs to #{inspect(own.slug)}, so service.id must be that."}

      bad = Enum.find(checks, &(not is_map(&1) or &1["type"] not in @app_check_types)) ->
        {:error,
         "An app key may declare checks of type #{Enum.join(@app_check_types, " or ")} only, not #{inspect(is_map(bad) && bad["type"])}."}

      length(checks) + length(jobs) > @app_checks ->
        {:error, "A service takes at most #{@app_checks} checks from an app key."}

      Enum.any?(jobs, &(not is_map(&1))) ->
        {:error, "Every job needs an id."}

      true ->
        about =
          Map.merge(about, %{"kind" => to_string(own.kind), "name" => about["name"] || own.name})

        declare(own.machine_id, %{
          "schema" => doc["schema"],
          "service" => about,
          "check" => checks,
          "job" => Enum.map(jobs, &Map.take(&1, @app_job_fields))
        })
    end
  end

  def declare(_, _), do: {:error, "A declaration needs [service] with an id."}

  # A check that names its own fail_after keeps it when the server's default changes.
  defp own_fail_after(config, %{"fail_after" => n}) when is_integer(n),
    do: Map.put(config, "own_fail_after", true)

  defp own_fail_after(config, _), do: config

  # Process and service checks are named by type, so their own name stays in the config.
  defp config_drop(type) when type in ~w(process windows-service systemd), do: ~w(type fail_after)
  defp config_drop(_), do: ~w(type name fail_after)

  # Named as the program names them: by the type for process, windows-service and systemd, otherwise
  # by the name or the type, numbered when a base repeats.
  defp named(checks) do
    {list, _} =
      checks
      |> Enum.filter(&is_map/1)
      |> Enum.map_reduce(%{}, fn c, seen ->
        type = to_string(c["type"])

        base =
          if is_binary(c["name"]) and c["name"] != "" and
               type not in ~w(process windows-service systemd),
             do: c["name"],
             else: type

        n = Map.get(seen, base, 0) + 1
        {{if(n == 1, do: base, else: "#{base}-#{n}"), c}, Map.put(seen, base, n)}
      end)

    list
  end

  # Open issues of a dropped check close, and tell the alerting, before the check goes.
  defp drop_checks(query, service) do
    ids = Repo.all(from c in query, select: c.id)
    now = DateTime.utc_now()

    open =
      Repo.all(from i in Dokkit.Issue, where: i.check_id in ^ids and is_nil(i.closed_at))

    for issue <- open do
      Repo.update!(Ecto.Changeset.change(issue, closed_at: now, check_id: nil))
      Dokkit.Alerts.closing(issue)
    end

    Repo.delete_all(from c in Check, where: c.id in ^ids)
    Dokkit.Issues.refresh(service)
  end

  defp route(value), do: if((c = Dokkit.Alerts.choice(value)) != "", do: c)

  @doc "Changes how a machine going silent is announced: its channels (empty for the server-wide choice) and whether it wakes someone at night."
  def set_silent(%Machine{} = machine, params) do
    change = for k <- ["down"], Map.has_key?(params, k), do: {:silent_route, route(params[k])}

    change =
      case params["night"] do
        v when v in [true, "true"] -> [silent_wake: true] ++ change
        v when v in [false, "false"] -> [silent_wake: false] ++ change
        _ -> change
      end

    machine = Repo.update!(Ecto.Changeset.change(machine, change))

    if change[:silent_wake] do
      Dokkit.Alerts.wake_machine(machine)
      Dokkit.Issues.changed()
    end

    machine
  end

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

  @doc """
  Sets one of a service's own switches: `:held`, a version kept on purpose so that being
  behind is not news; `:restart`, letting the installed program start its Windows service
  when it has stopped; `:keep_messages`, keeping the text of its errors from now on.
  """
  def set(%Service{} = service, field, value) when field in [:held, :restart, :keep_messages] do
    value =
      if field == :held,
        do: (is_binary(value) and value != "" and value) || nil,
        else: value == true

    Repo.update!(Ecto.Changeset.change(service, [{field, value}]))
  end

  @runs ~w(http tcp process windows-service systemd)

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
        {:error,
         "Each check needs a name and a type of http, tcp, process, windows-service or systemd."}

      names != Enum.uniq(names) or Enum.any?(names, &(&1 in from_file)) ->
        {:error, "Two checks of a service cannot share a name."}

      true ->
        drop_checks(from(c in mine, where: c.name not in ^names), service)

        for {name, type, config, fail_after} <- wanted do
          check =
            Repo.get_by(Check, service_id: service.id, name: name) ||
              %Check{service_id: service.id, name: name}

          {after_n, config} =
            if is_integer(fail_after) and fail_after in 1..100,
              do: {fail_after, Map.put(config, "own_fail_after", true)},
              else:
                {check.fail_after,
                 Map.take(check.config || %{}, ["own_fail_after"]) |> Map.merge(config)}

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
    # A field that is not given stays as it was.
    change =
      for {field, key} <- [route_down: "down", route_degraded: "degraded"],
          Map.has_key?(params, key),
          do: {field, route(params[key])}

    change =
      case params["night"] do
        v when v in [true, "true"] -> [night: true] ++ change
        v when v in [false, "false"] -> [night: false] ++ change
        _ -> change
      end

    service = Repo.update!(Ecto.Changeset.change(service, change))

    if change[:night] do
      Dokkit.Alerts.wake(service)
      Dokkit.Issues.changed()
    end

    service
  end

  @doc "Changes when a job counts as late and as run too long. A job from a dokkit.toml is read-only."
  def set_job_timing(%Check{type: :job, source: :reported} = check, params) do
    # A field that is not given stays as it was; an empty one clears it.
    timing =
      for k <- ~w(grace max_runtime),
          Map.has_key?(params, k),
          do: {k, String.trim(params[k] || "")}

    if Enum.all?(timing, fn {_, v} -> v == "" or v =~ @duration end) do
      config =
        Map.drop(check.config, Enum.map(timing, &elem(&1, 0)))
        |> Map.merge(Map.reject(Map.new(timing), &(elem(&1, 1) == "")))

      {:ok, Repo.update!(Ecto.Changeset.change(check, config: config))}
    else
      {:error, @duration_error}
    end
  end

  def set_job_timing(_, _), do: {:error, "Set in its dokkit.toml."}
end
