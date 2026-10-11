defmodule Dokkit.Intake.Refused do
  defexception [:code, :message]
end

defmodule Dokkit.Intake do
  @moduledoc "Everything that arrives from machines and apps. See spec/api.md, Intake."
  import Ecto.Query
  require Logger
  alias Dokkit.{Batch, Check, Issues, JobRun, Key, Machine, Repo, Service}
  alias Dokkit.Intake.Refused

  @max_lines 10_000
  @app_checks 100
  @tail_bytes 16 * 1024
  @states %{"ok" => :ok, "degraded" => :degraded, "down" => :down}
  @events ~w(start progress ok fail)

  def report(%Key{} = key, batch_id, body, now \\ DateTime.utc_now()) do
    lines = String.split(body, "\n", trim: true)
    stored = batch_id && Repo.get_by(Batch, id: batch_id, key_id: key.id)

    cond do
      length(lines) > @max_lines ->
        {:error, :too_large}

      stored ->
        {:ok, answer(stored)}

      true ->
        lines = Enum.map(lines, &decode/1)
        # A month's partition is made before the transaction, never inside it.
        Enum.each(lines, fn
          {:ok, %{"type" => "log"} = line} -> Dokkit.Logs.ensure_partition(line, now)
          _ -> nil
        end)

        Repo.transaction(fn -> store(key, batch_id, lines, now) end)
        |> tap(&heard(&1, key, for({:ok, %{"host" => h}} <- lines, do: h), now))
    end
    |> tap(fn _ -> Issues.changed() end)
  end

  @doc """
  Trades a one-use enrolment token for a machine and its key. A name that is already enrolled
  is refused unless the token was minted for that name, which revokes that machine's earlier keys.
  """
  def enrol(token, params) do
    name = String.trim(to_string(params["hostname"] || ""))

    with true <- name != "",
         {:ok, %Key{used_at: nil} = enrol} <- Dokkit.Keys.verify(token, :enrol) do
      replace = enrol.label == name

      Repo.transaction(fn ->
        now = DateTime.utc_now()

        spend = from(k in Key, where: k.id == ^enrol.id and is_nil(k.used_at))

        with {0, _} <- Repo.update_all(spend, set: [used_at: now, revoked_at: now]),
             do: Repo.rollback(:spent)

        attrs = [
          kind: :enrolled,
          os: params["os"],
          arch: params["arch"],
          program_version: params["dokkit"],
          last_seen_at: now
        ]

        machine =
          case Repo.get_by(Machine, name: name) do
            nil ->
              Repo.insert!(struct!(Machine, [name: name] ++ attrs))

            %Machine{kind: :enrolled} when not replace ->
              Repo.rollback(:taken)

            machine ->
              Repo.update_all(
                from(k in Key,
                  where:
                    k.machine_id == ^machine.id and k.kind == :machine and is_nil(k.revoked_at)
                ),
                set: [revoked_at: now]
              )

              Repo.update!(Ecto.Changeset.change(machine, attrs))
          end

        Repo.update_all(from(k in Key, where: k.id == ^enrol.id), set: [machine_id: machine.id])
        {key, _} = Dokkit.Keys.mint(:machine, %{machine_id: machine.id, label: name})
        %{machine: machine.id, key: key}
      end)
    else
      _ -> :error
    end
  end

  def ping(%Key{kind: :app} = key, name, event, run, tail) when event in @events do
    Repo.transaction(fn ->
      service = seen(key)
      line = clean(%{"name" => name, "event" => event, "run" => run, "tail" => tail})
      job(key, service, line, DateTime.utc_now())
    end)
    |> case do
      {:ok, ok} -> ok
      {:error, _} -> :error
    end
    |> tap(fn _ -> Issues.changed() end)
  rescue
    e in Refused -> {:error, e.code, e.message}
  end

  defp decode(text) do
    with {:ok, line} <- Jason.decode(text), do: {:ok, clean(line)}
  end

  # Postgres text and jsonb refuse NUL and invalid UTF-8.
  defp clean(text) when is_binary(text),
    do: text |> String.replace_invalid("") |> String.replace(<<0>>, "")

  defp clean(%{} = map), do: Map.new(map, fn {k, v} -> {clean(k), clean(v)} end)
  defp clean(list) when is_list(list), do: Enum.map(list, &clean/1)
  defp clean(other), do: other

  # A line the database refuses as bad data is refused alone; anything else fails the batch to be retried.
  defp guarded(fun) do
    Repo.query!("SAVEPOINT line")
    result = fun.()
    Repo.query!("RELEASE SAVEPOINT line")
    result
  rescue
    e ->
      if not data_error?(e), do: reraise(e, __STACKTRACE__)
      Repo.query!("ROLLBACK TO SAVEPOINT line")

      case e do
        %Refused{code: code, message: message} -> {:error, code, message}
        _ -> {:error, "bad_line", "The server could not store this line."}
      end
  end

  defp data_error?(%Refused{}), do: true
  defp data_error?(%DBConnection.EncodeError{}), do: true
  defp data_error?(%Ecto.InvalidChangesetError{}), do: true
  defp data_error?(%Ecto.ChangeError{}), do: true
  defp data_error?(%Ecto.Query.CastError{}), do: true

  defp data_error?(%Postgrex.Error{postgres: %{code: code, pg_code: pg}}),
    do: code != :unique_violation and is_binary(pg) and String.starts_with?(pg, ["22", "23"])

  defp data_error?(_), do: false

  defp store(key, batch_id, lines, now) do
    seen(key)
    hosts(key, for({:ok, %{"host" => host}} <- lines, do: host), now)

    results =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {decoded, n} ->
        with {:ok, %{"type" => type} = line} <- decoded,
             ok when ok == :ok or elem(ok, 0) == :log <-
               if(type == "log",
                 do: log_line(key, line, now),
                 else: guarded(fn -> line(key, type, line, at(line, now)) end)
               ) do
          ok
        else
          {:error, code, message} ->
            %{"line" => n, "code" => code, "message" => message}

          _ ->
            %{"line" => n, "code" => "bad_line", "message" => "Not a JSON object with a type."}
        end
      end)

    Dokkit.Logs.insert(for {:log, row} <- results, do: row)
    refused = Enum.filter(results, &is_map/1)

    batch = %Batch{
      id: batch_id,
      key_id: key.id,
      accepted: length(lines) - length(refused),
      refused: refused
    }

    if batch_id, do: Repo.insert!(batch)
    answer(batch)
  end

  defp answer(batch), do: %{accepted: batch.accepted, refused: batch.refused}

  defp line(%Key{kind: :app}, type, _, _) when type in ~w(state inventory),
    do: {:error, "not_allowed", "An app key may not send #{type}."}

  defp line(key, type, line, at) when type in ~w(state custom) do
    with {:ok, service} <- service(key, line),
         {:ok, state} <- Map.fetch(@states, line["state"]),
         name when is_binary(name) <- line["check"] do
      check = check(key, service, name, :custom, 3)
      Issues.record(check, state, at: at, note: line["note"], value: number(line["value"]))
      :ok
    else
      {:error, _, _} = refusal -> refusal
      _ -> {:error, "bad_line", "Needs check and a state of ok, degraded or down."}
    end
  end

  defp line(key, "beat", line, at) do
    with {:ok, service} <- service(key, line), name when is_binary(name) <- line["name"] do
      every = line["every_seconds"]
      config = %{"every_seconds" => if(is_integer(every) and every > 0, do: every, else: 60)}
      check = check(key, service, name, :beat, 1)

      check =
        if check.config == config,
          do: check,
          else: Repo.update!(Ecto.Changeset.change(check, config: config))

      Issues.record(check, :ok, at: at)
      :ok
    else
      {:error, _, _} = refusal -> refusal
      _ -> {:error, "bad_line", "A beat needs a name."}
    end
  end

  defp line(key, "metric", line, at) do
    service =
      case {key, line} do
        {%Key{kind: :machine}, line} when not is_map_key(line, "service") -> {:ok, nil}
        _ -> service(key, line)
      end

    with {:ok, service} <- service,
         do:
           Dokkit.Numbers.record(machine(key, service), service, line["name"], line["value"], at)
  end

  defp line(key, "stats", line, at) do
    with {:ok, service} <- service(key, line),
         :ok <- Dokkit.Numbers.stats(service, line["document"], at) do
      Issues.record(check(key, service, "stats", :stats, 3), :ok, at: at)
      :ok
    end
  end

  defp line(key, "deploy", line, at) do
    with {:ok, service} <- service(key, line),
         version when is_binary(version) <- line["version"] do
      case elsewhere(key, service, line["host"]) do
        nil ->
          Dokkit.Deploys.record(service, version,
            how: "reported",
            commit: label_text(line["commit"]),
            by: label_text(line["by"])
          )

        machine_id ->
          Dokkit.Deploys.installed(service, machine_id, version, at)
      end
    else
      {:error, _, _} = refusal -> refusal
      _ -> {:error, "bad_line", "A deploy needs a version."}
    end
  end

  defp line(key, "job", line, at) do
    with {:ok, service} <- service(key, line), true <- line["event"] in @events do
      job(key, service, line, at)
    else
      {:error, _, _} = refusal -> refusal
      _ -> {:error, "bad_line", "Needs an event of start, progress, ok or fail."}
    end
  end

  defp line(%Key{kind: :machine, machine_id: id}, "inventory", line, _at) do
    change =
      for {field, key} <- [os: "os", arch: "arch", program_version: "dokkit"],
          is_binary(line[key]),
          do: {field, line[key]}

    Repo.update_all(from(m in Machine, where: m.id == ^id), set: [kind: :enrolled] ++ change)

    for %{"id" => slug, "version" => version} <- List.wrap(line["services"]),
        is_binary(slug) and is_binary(version),
        service = Repo.get_by(Service, machine_id: id, slug: slug),
        do: Dokkit.Deploys.record(service, version)

    :ok
  end

  defp line(_, type, _, _), do: {:error, "unknown_type", "Unknown type #{inspect(type)}."}

  # The row's time is the sender's; received_at is the server's, so the offset is their difference.
  defp log_line(key, line, now) do
    with {:ok, service} <- log_service(key, line) do
      {:log, Dokkit.Logs.row(line, machine(key, service), service && service.id, now)}
    end
  end

  # The host an app reports from, when that is not the machine its service lives on.
  defp elsewhere(%Key{kind: :app}, service, host) when is_binary(host) and host != "" do
    case Repo.get_by(Machine, name: String.slice(host, 0, 100)) do
      %Machine{id: id} when id != service.machine_id -> id
      _ -> nil
    end
  end

  defp elsewhere(_, _, _), do: nil

  # Slots are written once the batch is stored, so a rolled back batch leaves no mark.
  defp heard({:ok, _}, %Key{kind: :machine, machine_id: id}, _, now),
    do: Dokkit.Slots.touch(id, now)

  defp heard({:ok, _}, %Key{kind: :app}, hosts, now),
    do: Dokkit.Slots.touch_named(host_names(hosts), now)

  defp heard(_, _, _, _), do: :ok

  defp host_names(hosts),
    do:
      hosts
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.take(50)
      |> Enum.map(&String.slice(&1, 0, 100))

  @max_seen 500
  @max_seen_per_key 200

  # An app says which host it runs on. That host becomes a machine that was seen, with no dokkit on it.
  # Each app key can make 200 of them and the estate 500, so one leaked key cannot fill the estate or lock the others out.
  defp hosts(%Key{kind: :app, id: key_id}, hosts, now) do
    case host_names(hosts) do
      [] ->
        nil

      names ->
        known = Repo.all(from m in Machine, where: m.name in ^names, select: m.name)
        seen = from(m in Machine, where: m.kind == :seen)
        mine = Repo.aggregate(from(m in seen, where: m.seen_by == ^key_id), :count)
        room = min(@max_seen_per_key - mine, @max_seen - Repo.aggregate(seen, :count))
        {new, refused} = Enum.split(names -- known, max(room, 0))

        if refused != [],
          do:
            Logger.warning(
              "Refused #{length(refused)} new hosts named by an app: #{@max_seen_per_key} for each key and #{@max_seen} in all is the most."
            )

        rows =
          for host <- known ++ new do
            %{
              id: Ecto.UUID.generate(),
              name: host,
              kind: :seen,
              seen_by: key_id,
              last_seen_at: now,
              inserted_at: now,
              updated_at: now
            }
          end

        Repo.insert_all(Machine, rows,
          on_conflict:
            from(m in Machine, where: m.kind == :seen, update: [set: [last_seen_at: ^now]]),
          conflict_target: :name
        )
    end
  end

  defp hosts(_, _, _), do: nil

  @doc "An error report, in the format of spec/errors.md."
  def error(%Key{} = key, report) do
    report = clean(report)
    seen(key)
    now = DateTime.utc_now()
    hosts(key, [report["host"]], now)
    heard({:ok, nil}, key, [report["host"]], now)
    with {:ok, service} <- service(key, report), do: Dokkit.Errors.report(service, report)
  end

  @doc "A deploy told to the server on its own, as CI does."
  def deploy(%Key{} = key, params) do
    params = clean(params)
    seen(key)
    line(key, "deploy", params, DateTime.utc_now())
  end

  defp label_text(value), do: if(is_binary(value), do: String.slice(value, 0, 100))

  defp job(key, service, line, at) do
    name = line["name"] || service.slug
    check = check(key, service, name, :job, 1)

    check =
      if check.config["waiting"],
        do:
          Repo.update!(Ecto.Changeset.change(check, config: Map.delete(check.config, "waiting"))),
        else: check

    event = line["event"]
    run = find_run(check, line["run"], event)

    changes =
      %{
        "start" => [result: :running, started_at: at],
        "progress" => [],
        "ok" => [result: :ok, finished_at: at],
        "fail" => [result: :fail, finished_at: at]
      }[event]
      |> Keyword.merge(
        for {k, v} <- [
              exit_code: line["exit_code"],
              duration_ms: line["duration_ms"],
              done: line["done"],
              total: line["total"]
            ],
            is_integer(v),
            do: {k, v}
      )
      |> Keyword.merge(
        if is_binary(line["tail"]) and line["tail"] != "",
          do: [tail: tail(line["tail"])],
          else: []
      )

    new? = Ecto.get_meta(run, :state) == :built
    run = Repo.insert_or_update!(Ecto.Changeset.change(run, changes))

    # A new start means any earlier run still marked running was cut short.
    if event == "start" and new?,
      do:
        Repo.update_all(
          from(r in JobRun,
            where:
              r.check_id == ^check.id and r.result == :running and r.id != ^run.id and
                r.started_at < ^at
          ),
          set: [result: :fail, finished_at: at]
        )

    case event do
      "ok" ->
        case Dokkit.Watch.ran_long(check, run, label(service, name)) do
          {title, note} ->
            Issues.record(check, :degraded, at: at, soon: true, title: title, note: note)

          nil ->
            Issues.record(check, :ok, at: at)
        end

      "fail" ->
        Issues.record(check, :down,
          at: at,
          note: failure(run),
          title: "#{label(service, name)} failed"
        )

      _ ->
        nil
    end

    :ok
  end

  defp find_run(check, id, event) do
    found =
      cond do
        is_binary(id) ->
          Repo.get_by(JobRun, check_id: check.id, run: id)

        event == "start" ->
          nil

        true ->
          Repo.one(
            from r in JobRun,
              where: r.check_id == ^check.id and r.result == :running,
              order_by: [desc: r.started_at],
              limit: 1
          )
      end

    found || %JobRun{check_id: check.id, run: (is_binary(id) && id) || Ecto.UUID.generate()}
  end

  def label(%Service{slug: name, name: full}, name), do: full
  def label(_, name), do: name

  @doc "The address a job calls to say it started, finished (`ok`) or failed."
  def ping_url(key, slug, event),
    do: Dokkit.Certificate.url() <> "/api/v1/in/#{key}/job/#{slug}/#{event}"

  defp failure(%JobRun{tail: tail}) when is_binary(tail),
    do:
      tail
      |> String.split(["\r\n", "\n"], trim: true)
      |> List.last()

  defp failure(%JobRun{exit_code: code}) when is_integer(code), do: "Exit code #{code}"
  defp failure(_), do: "Reported as failed"

  defp tail(text) do
    size = byte_size(text)

    if size > @tail_bytes,
      do: binary_part(text, size - @tail_bytes, @tail_bytes) |> clean(),
      else: clean(text)
  end

  defp service(%Key{kind: :app, service_id: id}, line),
    do: environment(Repo.get!(Service, id), line["environment"])

  defp service(%Key{kind: :machine, machine_id: machine}, %{"service" => slug} = line)
       when is_binary(slug) do
    case Repo.get_by(Service, machine_id: machine, slug: slug) do
      nil -> {:error, "unknown_service", "No service #{inspect(slug)} on this machine."}
      service -> environment(service, line["environment"])
    end
  end

  defp service(_, _), do: {:error, "bad_line", "Needs a service."}

  @max_variants 5

  # A service with a declaration keeps its own environment. Otherwise a line from another
  # environment goes to a sibling row of the same machine, so production is never changed by it.
  defp environment(%Service{declared: nil} = base, env) when is_binary(env) do
    env = env |> String.trim() |> String.downcase()

    if env == "production" or not (env =~ ~r/^[a-z0-9][a-z0-9._-]{0,31}$/),
      do: {:ok, base},
      else: variant(base, env)
  end

  defp environment(base, _), do: {:ok, base}

  defp variant(base, env) do
    slug = "#{base.slug}~#{env}"
    prefix = base.slug <> "~"

    siblings =
      Repo.aggregate(
        from(s in Service,
          where:
            s.machine_id == ^base.machine_id and
              fragment("left(?, ?) = ?", s.slug, ^String.length(prefix), ^prefix)
        ),
        :count
      )

    case Repo.get_by(Service, machine_id: base.machine_id, slug: slug) do
      nil when siblings >= @max_variants ->
        {:error, "too_many_environments",
         "A service takes lines from at most #{@max_variants} other environments."}

      nil ->
        Repo.insert!(
          %Service{
            machine_id: base.machine_id,
            slug: slug,
            name: "#{base.name} (#{env})",
            kind: base.kind,
            environment: env,
            watched: base.watched
          },
          on_conflict: :nothing,
          conflict_target: [:machine_id, :slug]
        )

        {:ok, Repo.get_by!(Service, machine_id: base.machine_id, slug: slug)}

      service ->
        {:ok, service}
    end
  end

  # A machine may log without naming a service.
  defp log_service(%Key{kind: :machine}, line) when not is_map_key(line, "service"),
    do: {:ok, nil}

  defp log_service(key, line), do: service(key, line)

  defp machine(%Key{machine_id: id}, nil), do: id
  defp machine(_, service), do: service.machine_id

  defp check(key, service, name, type, fail_after) do
    Repo.get_by(Check, service_id: service.id, name: name) ||
      Repo.insert!(%Check{
        service_id: service.id,
        name: room(key, service, name),
        type: type,
        source: :reported,
        fail_after: fail_after
      })
  end

  # An app key can make only so many checks, so a leaked key cannot fill the database.
  defp room(%Key{kind: :app}, service, name) do
    if Repo.aggregate(from(c in Check, where: c.service_id == ^service.id), :count) >= @app_checks,
      do:
        raise(Refused,
          code: "too_many_checks",
          message: "A service takes at most #{@app_checks} checks from an app key."
        ),
      else: name
  end

  defp room(_, _, name), do: name

  defp seen(%Key{} = key) do
    now = DateTime.utc_now()
    service = key.service_id && Repo.get!(Service, key.service_id)
    machine = key.machine_id || (service && service.machine_id)

    if key.kind == :machine,
      do: Repo.update_all(from(m in Machine, where: m.id == ^machine), set: [last_seen_at: now])

    Repo.update_all(from(k in Key, where: k.id == ^key.id), set: [used_at: now])
    service
  end

  defp at(%{"at" => text}, now) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _} ->
        if DateTime.compare(at, now) == :gt,
          do: now,
          else: %{at | microsecond: {elem(at.microsecond, 0), 6}}

      _ ->
        now
    end
  end

  defp at(_, now), do: now

  defp number(v) when is_number(v), do: v / 1
  defp number(_), do: nil
end
