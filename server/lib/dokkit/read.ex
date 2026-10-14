defmodule Dokkit.Read do
  @moduledoc "What the API and the MCP answer with, as plain maps."
  import Ecto.Query, only: [from: 2, dynamic: 2]
  alias Dokkit.{Estate, Install, Issue, Issues, Logs, Machine, MachineSlot, Repo, Service, Slots}

  def inbox do
    %{needs_you: needs_you, soon: soon, other: other} = Issues.groups()

    %{
      needs_you: Enum.map(needs_you, &issue/1),
      soon: Enum.map(soon, &issue/1),
      not_watched: for(f <- Dokkit.Found.list(), do: found(f)),
      snoozed: Enum.map(Issues.snoozed_list(), &issue/1),
      planned_downtime:
        for m <- Issues.machines(), m.planned do
          Map.merge(%{machine: m.name, id: m.id}, Dokkit.Quiet.view(m.planned))
        end,
      other_environments:
        for {env, list} <- Enum.group_by(other, & &1.service.environment) |> Enum.sort() do
          %{environment: env, issues: Enum.map(list, &issue/1)}
        end,
      fine: Issues.fine()
    }
  end

  @cells 48
  @states %{0 => "quiet", 1 => "degraded", 2 => "down"}

  @doc """
  The 48 half hours that end with the one holding `to`: for each machine a cell that is down,
  degraded, quiet or none (not heard from), and the issues that opened. An issue keeps its
  last state for its whole life. Soon issues and other environments are left out.
  """
  def day(to \\ DateTime.utc_now()) do
    step = Slots.step()
    last = Slots.slot(to)
    from = DateTime.add(last, -(@cells - 1) * step)
    edge = DateTime.add(last, step)
    us = step * 1_000_000
    index = &Integer.floor_div(DateTime.diff(&1, from, :microsecond), us)

    machines =
      Repo.all(
        from m in Machine,
          where: m.kind != :group,
          order_by: m.name,
          select: %{id: m.id, name: m.name, kind: m.kind}
      )

    issues =
      Repo.all(
        from i in Issue,
          left_join: s in assoc(i, :service),
          left_join: a in assoc(i, :alerts),
          where: not i.soon and i.since < ^edge,
          where: is_nil(i.closed_at) or i.closed_at > ^from,
          where: is_nil(s.id) or s.environment == "production",
          order_by: i.since,
          select: %{
            id: i.id,
            machine_id: i.machine_id,
            state: i.state,
            since: i.since,
            closed_at: i.closed_at,
            title: i.title,
            channel: a.channel,
            status: a.status
          }
      )

    heard =
      MapSet.new(
        Repo.all(
          from s in MachineSlot,
            where: s.slot >= ^from and s.slot <= ^last,
            select: {s.machine_id, s.slot}
        ),
        fn {id, slot} -> {id, index.(slot)} end
      )

    worst =
      Enum.reduce(issues, %{}, fn i, acc ->
        first = index.(i.since)

        stop =
          if i.closed_at,
            do:
              max(
                first,
                -Integer.floor_div(-DateTime.diff(i.closed_at, from, :microsecond), us) - 1
              ),
            else: @cells - 1

        rank = if i.state == :down, do: 2, else: 1

        Enum.reduce(max(first, 0)..min(stop, @cells - 1)//1, acc, fn n, acc ->
          Map.update(acc, {i.machine_id, n}, rank, &max(&1, rank))
        end)
      end)

    planned =
      Repo.all(
        from w in Dokkit.QuietWindow,
          where: w.started_at < ^edge and coalesce(w.ended_at, w.until) > ^from,
          select: {w.machine_id, w.started_at, coalesce(w.ended_at, w.until)}
      )
      |> Enum.flat_map(fn {id, first, last} ->
        for n <- max(index.(first), 0)..min(index.(last), @cells - 1)//1, do: {id, n}
      end)
      |> MapSet.new()

    rows =
      for m <- machines do
        cells =
          for n <- 0..(@cells - 1) do
            cond do
              rank = worst[{m.id, n}] -> @states[rank]
              {m.id, n} in planned -> "planned"
              {m.id, n} in heard -> "quiet"
              true -> "none"
            end
          end

        %{id: m.id, name: m.name, kind: m.kind, cells: cells}
      end

    names = Map.new(machines, &{&1.id, &1.name})

    %{
      from: from,
      to: edge,
      machines:
        for(
          m <- rows,
          m.kind == :enrolled or Enum.any?(m.cells, &(&1 != "none")),
          do: Map.delete(m, :kind)
        ),
      events:
        for i <- Enum.uniq_by(issues, & &1.id),
            DateTime.compare(i.since, from) != :lt,
            DateTime.compare(i.since, to) != :gt do
          %{
            at: i.since,
            title: i.title,
            machine: names[i.machine_id],
            state: i.state,
            sent:
              Enum.find_value(
                issues,
                &((&1.id == i.id and &1.status in [:sent, :closing, :closed]) &&
                    Dokkit.Alerts.sent_word(&1.channel))
              ),
            closed_at: i.closed_at
          }
        end
    }
  end

  def issues, do: Enum.map(Issues.open_list() ++ Issues.snoozed_list(), &issue/1)

  def machines do
    for m <- Issues.machines() do
      m
      |> Map.take([:id, :name, :kind, :os, :last_seen_at, :down])
      |> Map.put(:planned_downtime, Dokkit.Quiet.view(m.planned))
      |> Map.put(:needs_a_look, m.bad)
      |> Map.put(:vitals, Dokkit.Numbers.vitals()[m.id] || %{})
    end
  end

  def keys do
    for k <- Dokkit.Keys.list() do
      k
      |> Map.take([:id, :kind, :hint, :label, :scopes, :used_at, :expires_at, :inserted_at])
      |> Map.merge(%{machine: k.machine && k.machine.name, service: k.service_id})
    end
  end

  def users, do: for(u <- Dokkit.Accounts.list(), do: Map.take(u, [:id, :name, :role]))

  @doc "A service's own routing: the channels as text with commas, and as lists."
  def routing(s) do
    %{
      down: s.route_down,
      degraded: s.route_degraded,
      night: s.night,
      down_channels: Dokkit.Alerts.split(s.route_down),
      degraded_channels: Dokkit.Alerts.split(s.route_degraded)
    }
  end

  @doc "How a machine that stops reporting is announced. No channels means the server-wide choice for down."
  def silent(m) do
    %{
      down: m.silent_route,
      down_channels: Dokkit.Alerts.split(m.silent_route),
      night: m.silent_wake
    }
  end

  def machine(id) do
    with %{} = m <- Enum.find(machines(), &(&1.id == id)) do
      config = Dokkit.Alerts.config()

      Map.merge(m, %{
        silent: silent(Dokkit.Estate.machine(id)),
        schedules: Dokkit.QuietSchedules.list(id),
        downtime_history: Enum.map(Dokkit.Quiet.history(id), &Dokkit.Quiet.view/1),
        metrics: Dokkit.Numbers.machine_latest(id),
        services: services(%{"machine" => id}),
        thresholds: %{
          disk_used_percent: config["disk_limit"],
          memory_used_percent: config["memory_limit"]
        }
      })
    end
  end

  @doc "Which version of each service is on which machine."
  def versions do
    services(%{})
    |> Enum.group_by(&{&1.name, &1.slug})
    |> Enum.sort()
    |> Enum.map(fn {{name, slug}, rows} ->
      %{
        slug: slug,
        name: name,
        on: Enum.map(rows, &Map.take(&1, [:machine, :version, :held, :environment]))
      }
    end)
  end

  @doc "Apps that run on many hosts, with the hosts on each version."
  def apps do
    for a <- Dokkit.Deploys.apps() do
      %{
        id: a.service.id,
        slug: a.service.slug,
        name: a.service.name,
        hosts: a.hosts,
        versions: for({version, hosts} <- a.versions, do: %{version: version, hosts: hosts})
      }
    end
  end

  @doc "One issue, open or closed, with its notes."
  def one_issue(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Issue{} = i <- Repo.get(Issue, id) do
      i = Repo.preload(i, [:machine, :service, :check, :alerts])

      Map.merge(issue(i), %{closed_at: i.closed_at, notes: i.notes, history: history(i)})
      |> then(&if(i.processes, do: Map.put(&1, :processes, i.processes), else: &1))
    else
      _ -> nil
    end
  end

  defp history(i) do
    notes =
      for n <- i.notes,
          {:ok, at, _} <- [DateTime.from_iso8601(to_string(n["at"]))],
          do: %{at: at, event: "note", by: n["by"], note: n["text"]}

    ([%{at: i.since, event: "opened"}] ++
       notes ++
       if(i.acknowledged_at, do: [%{at: i.acknowledged_at, event: "acknowledged"}], else: []) ++
       if(i.snoozed_until, do: [%{at: nil, event: "snoozed", until: i.snoozed_until}], else: []) ++
       if(i.closed_at, do: [%{at: i.closed_at, event: "closed"}], else: []))
    |> Enum.sort_by(&DateTime.to_unix(&1.at || i.since, :microsecond))
  end

  @doc "What waits to be accepted: the things a scan found."
  def proposals, do: for(f <- Dokkit.Found.list(), do: found(f))

  @doc "Issues that open again and again, where the digest would do. A person accepts or dismisses."
  def suggestions do
    for i <- Dokkit.Alerts.suggestions() do
      %{
        id: i.id,
        service: i.service_id,
        name: i.service.name,
        state: i.state,
        count: i.count
      }
    end
  end

  @doc "The archived months of logs that can be loaded back."
  def archives do
    dir = Application.get_env(:dokkit, :archive)
    for a <- (dir && Logs.archives(dir)) || [], do: Map.take(a, [:name, :size, :back_until])
  end

  @doc "The program version the server holds for machines to fetch, and what each machine runs."
  def program do
    %{
      held: Dokkit.Work.program_version(),
      machines:
        for m <- Estate.machines(), m.kind != :group, m.program_version do
          %{id: m.id, machine: m.name, version: m.program_version}
        end
    }
  end

  def services(params) do
    q = String.downcase(params["q"] || "")

    for m <- Estate.machines(),
        s <- m.services,
        params["machine"] in [nil, m.id, m.name],
        params["environment"] in [nil, s.environment],
        params["kind"] in [nil, to_string(s.kind)],
        params["service"] in [nil, s.id, s.slug],
        q == "" or String.contains?(String.downcase(s.name <> " " <> s.slug), q),
        do: service_row(s, m)
  end

  def service(id) do
    with %{} = s <- Estate.service(id) do
      open = Estate.open_issue(s)

      checks =
        for c <- s.checks,
            do: Map.take(c, [:name, :type, :state, :note, :value, :checked_at, :source, :config])

      Map.merge(service_row(s, s.machine), %{
        checks: checks,
        routing: routing(s),
        restart: s.restart,
        keep_messages: s.keep_messages,
        stats: s.stats,
        stats_at: s.stats_at,
        facts: (s.declared && s.declared["service"]) || %{},
        versions: versions_of(s),
        deploys: deploys(service: s.id, limit: 10),
        open_issue: open && issue(Repo.preload(open, [:machine, :service, :check, :alerts]))
      })
    end
  end

  defp versions_of(%{kind: :app} = s) do
    for i <-
          Repo.all(
            from i in Install,
              where: i.service_id == ^s.id,
              order_by: [desc: i.seen_at],
              preload: :machine
          ),
        do: %{machine: i.machine.name, version: i.version, seen_at: i.seen_at}
  end

  defp versions_of(s) do
    Repo.all(
      from x in Service,
        join: m in assoc(x, :machine),
        where: x.slug == ^s.slug,
        order_by: m.name,
        select: %{machine: m.name, version: x.version, held: x.held, environment: x.environment}
    )
  end

  def jobs(params \\ %{}) do
    for j <- Estate.jobs(),
        params["machine"] in [nil, j.machine.id, j.machine.name],
        params["service"] in [nil, j.service.id, j.service.slug],
        params["environment"] in [nil, j.service.environment],
        params["state"] in [nil, to_string(j.check.state)],
        like?(params, [j.service.name, j.check.name]) do
      %{
        id: j.service.id,
        name: Dokkit.Intake.label(j.service, j.check.name),
        machine: j.machine.name,
        state: j.check.state,
        schedule: j.check.config["schedule"],
        grace: j.check.config["grace"],
        max_runtime: j.check.config["max_runtime"],
        last_run: j.last && run(j.last),
        last_good_run: j.good,
        next_expected: Estate.next_expected(j.check)
      }
    end
  end

  def runs(id) do
    with %{} = s <- Estate.service(id), do: Enum.map(Estate.runs(s, 100), &run/1)
  end

  @log_keys [:tail, :output, :message, :notes, :note]

  @doc "The answer without job output, error messages and issue notes, for a token that may not read logs."
  def without_logs(%{__struct__: _} = x), do: x

  def without_logs(%{} = m),
    do: m |> Map.drop(@log_keys) |> Map.new(fn {k, v} -> {k, without_logs(v)} end)

  def without_logs(list) when is_list(list), do: Enum.map(list, &without_logs/1)
  def without_logs(x), do: x

  @doc "The newest 500 log lines that match, or nil when a service or machine is named and does not exist, or a time is not one."
  def logs(params) do
    case list(:logs, Map.delete(params, "cursor")) do
      %{items: items} -> items
      _ -> nil
    end
  end

  def deploys(opts \\ []), do: Enum.map(Dokkit.Deploys.list(opts), &deploy/1)

  defp deploy(d) do
    d
    |> Map.take([:from, :version, :commit, :by, :how, :at])
    |> Map.merge(%{
      service: d.service_id,
      name: d.service.name,
      machine: d.service.machine.name
    })
  end

  @doc "The latest deploy of a service, and the issues and errors first seen after it."
  def since_deploy(id) do
    with %{} = s <- Estate.service(id) do
      case deploys(service: s.id, limit: 1) do
        [] ->
          %{deploy: nil, issues_since: [], errors_since: []}

        [deploy] ->
          issues =
            Repo.all(
              from i in Issue,
                where: i.service_id == ^s.id and i.since >= ^deploy.at,
                order_by: i.since,
                preload: [:machine, :service, :check, :alerts]
            )

          %{
            deploy: deploy,
            issues_since: Enum.map(issues, &issue/1),
            errors_since: errors(service: s.id, since: deploy.at)
          }
      end
    end
  end

  def errors(opts \\ []), do: Enum.map(Dokkit.Errors.list(opts), &error_group/1)

  def error(id, params \\ %{}) do
    with %{group: group, latest: latest} <- Dokkit.Errors.get(id),
         {:ok, at} <- cursor_at(params) do
      n = limit(params)

      events =
        Repo.all(
          from e in Dokkit.ErrorEvent,
            where: e.group_id == ^group.id,
            where: ^after_time(at, :at),
            order_by: [desc: e.at, desc: e.id],
            limit: ^(n + 1)
        )

      reports =
        events
        |> cut(n, &tkey(&1.at, &1.id))
        |> mapped(&Map.take(&1, [:id, :at, :release, :host, :handled, :message, :tags, :frames]))

      Map.merge(error_group(group), %{
        frames: (latest && latest.frames) || [],
        tags: (latest && latest.tags) || %{},
        message: latest && latest.message,
        reports: reports
      })
    end
  end

  defp error_group(g) do
    g
    |> Map.take([:id, :type, :top, :count, :first_seen, :last_seen, :release, :host, :handled])
    |> Map.merge(%{service: g.service_id, name: g.service.name, machine: g.service.machine.name})
  end

  @doc "Chart data for one service. nil when the service or the times are not there."
  def series(id, params) do
    with %{} = s <- Estate.service(id), do: chart(s.id, params)
  end

  @doc "Chart data for a machine's own numbers, like a service's."
  def machine_series(id, params) do
    with %{} <- Enum.find(Issues.machines(), &(&1.id == id)), do: chart({:machine, id}, params)
  end

  @doc "A machine's newest process list. nil when there is no such machine."
  def processes(id, params) do
    with %Machine{} = m <- Dokkit.Processes.machine(id), do: Dokkit.Processes.list(m, params)
  end

  @doc "The top lists kept for a machine over up to 24 hours, oldest first."
  def process_history(id, params) do
    now = DateTime.utc_now()
    kind = params["kind"] || "memory"

    with %Machine{} = m <- Dokkit.Processes.machine(id),
         {:ok, to} <- time(params["to"], now),
         {:ok, from} <- time(params["from"], DateTime.add(to, -3600)),
         true <- kind in ~w(memory cpu),
         :lt <- DateTime.compare(from, to) do
      from = Enum.max([from, DateTime.add(now, -86_400)], DateTime)
      %{kind: kind, samples: Dokkit.Processes.history(m, kind, from, to)}
    else
      nil ->
        nil

      _ ->
        {:error, "bad_range",
         "from and to are RFC 3339 with from before to, and kind is memory or cpu."}
    end
  end

  defp chart(owner, params) do
    now = DateTime.utc_now()

    with {:ok, to} <- time(params["to"], now),
         {:ok, from} <- time(params["from"], DateTime.add(to, -86_400)),
         :lt <- DateTime.compare(from, to) do
      points =
        case Integer.parse(params["points"] || "") do
          {n, ""} when n in 1..500 -> n
          _ -> 24
        end

      case params["metric"] do
        nil -> %{metrics: Dokkit.Numbers.names(owner)}
        name -> %{metric: name, points: Dokkit.Numbers.series(owner, name, from, to, points)}
      end
    else
      _ -> nil
    end
  end

  @default_limit 100
  @max_limit 500
  @reach 1000

  defp limit(params, default \\ @default_limit) do
    n = params["limit"]
    n = if is_float(n), do: trunc(n), else: n

    case Integer.parse(to_string(n)) do
      {n, ""} when n >= 1 -> min(n, @max_limit)
      _ -> default
    end
  end

  @doc """
  One page of a list: `%{items: [...], next: cursor or nil}`, or an error tuple. A cursor is
  the sort key of the last item, so a page is the same whatever is added or removed meanwhile.
  `q`, `machine`, `service`, `environment`, `from` and `to` narrow the list where they make sense.
  """
  def list(:issues, params) do
    with {:ok, at} <- cursor_at(params),
         {:ok, from, to} <- times(params),
         {:ok, state} <- issue_state(params["state"]) do
      n = limit(params)
      now = DateTime.utc_now()

      filters = [
        state.(now),
        params["machine"] &&
          dynamic(
            [i, s, m],
            m.name == ^params["machine"] or fragment("?::text", m.id) == ^params["machine"]
          ),
        params["service"] &&
          case Ecto.UUID.cast(params["service"]) do
            {:ok, id} -> dynamic([i], i.service_id == ^id)
            _ -> dynamic([], false)
          end,
        params["environment"] && dynamic([i, s], s.environment == ^params["environment"]),
        like_text(params["q"]) &&
          dynamic(
            [i],
            ilike(i.title, ^like_text(params["q"])) or
              ilike(fragment("'DOK-' || ?::text", i.number), ^like_text(params["q"]))
          ),
        from && dynamic([i], i.since >= ^from),
        to && dynamic([i], i.since <= ^to),
        after_time(at, :since)
      ]

      Repo.all(
        from i in Issue,
          left_join: s in assoc(i, :service),
          left_join: m in assoc(i, :machine),
          where: ^all_of(filters),
          order_by: [desc: i.since, desc: i.id],
          limit: ^(n + 1),
          preload: [:machine, :service, :check, :alerts]
      )
      |> cut(n, &tkey(&1.since, &1.id))
      |> mapped(&issue/1)
    end
  end

  def list(:machines, params) do
    for(
      m <- machines(),
      like?(params, [m.name, m.os]),
      params["machine"] in [nil, m.id, m.name],
      do: m
    )
    |> page(params, &(down(&1.name) <> "\0" <> &1.id))
  end

  def list(:services, params),
    do: services(params) |> page(params, &(down(&1.machine <> "\0" <> &1.name) <> &1.id))

  def list(:jobs, params),
    do: jobs(params) |> page(params, &(down(&1.machine <> "\0" <> &1.name) <> &1.id))

  def list({:runs, id}, params) do
    with %{} = s <- Estate.service(id),
         {:ok, at} <- cursor_at(params),
         {:ok, from, to} <- times(params) do
      n = limit(params)

      Estate.runs(s, n + 1,
        after: at,
        from: from,
        to: to,
        result: params["result"]
      )
      |> cut(n, &tkey(&1.started_at || &1.finished_at, &1.id))
      |> mapped(&run/1)
    end
  end

  def list(:deploys, params) do
    with {:ok, from, to} <- times(params) do
      Dokkit.Deploys.list(limit: @reach)
      |> Enum.filter(fn d ->
        params["service"] in [nil, d.service_id, d.service.slug] and
          params["machine"] in [nil, d.service.machine.id, d.service.machine.name] and
          params["environment"] in [nil, d.service.environment] and
          like?(params, [d.service.name, d.version, d.commit, d.by]) and within?(d.at, from, to)
      end)
      |> page(params, &tkey(&1.at, &1.id), :desc)
      |> mapped(&deploy/1)
    end
  end

  def list(:errors, params) do
    with {:ok, from, to} <- times(params) do
      Dokkit.Errors.list(limit: @reach)
      |> Enum.filter(fn g ->
        params["service"] in [nil, g.service_id, g.service.slug] and
          params["machine"] in [nil, g.service.machine.id, g.service.machine.name] and
          params["environment"] in [nil, g.service.environment] and
          like?(params, [g.type, g.top, g.service.name]) and within?(g.last_seen, from, to)
      end)
      |> page(params, &tkey(&1.last_seen, &1.id), :desc)
      |> mapped(&error_group/1)
    end
  end

  def list(:rules, params),
    do:
      rules()
      |> Enum.filter(&like?(params, Map.values(&1)))
      |> ordered(params)

  def list(:proposals, params) do
    {hidden, shown} =
      for(
        f <- Dokkit.Found.list(system: true),
        params["machine"] in [nil, f.machine.id, f.machine.name],
        params["kind"] in [nil, f.kind],
        like?(params, [f.key, f.machine.name, f.detail["label"], f.detail["saw"]]),
        do: f
      )
      |> Enum.split_with(&(&1.origin == "system" and params["system"] not in [true, "true"]))

    case shown
         |> page(params, &(&1.kind <> "\0" <> down(&1.key) <> "\0" <> &1.id))
         |> mapped(&found/1) do
      %{items: _} = page ->
        Map.put(page, :hidden, %{
          total: length(hidden),
          machines: Enum.frequencies_by(hidden, & &1.machine.name)
        })

      other ->
        other
    end
  end

  def list(:keys, params) do
    with {:ok, from, to} <- times(params) do
      for(
        k <- keys(),
        like?(params, [k.label, k.hint]),
        params["kind"] in [nil, to_string(k.kind)],
        params["machine"] in [nil, k.machine],
        within?(k.inserted_at, from, to),
        do: k
      )
      |> page(params, &tkey(&1.inserted_at, &1.id), :desc)
    end
  end

  def list(:users, params),
    do:
      users()
      |> Enum.filter(&like?(params, [&1.name]))
      |> page(params, &(down(&1.name) <> "\0" <> &1.id))

  def list(:releases, params),
    do:
      Dokkit.Releases.list()
      |> Enum.filter(&like?(params, [&1.version]))
      |> ordered(params)

  def list(:logs, params) do
    service = params["service"] && Estate.service(params["service"])

    machine =
      params["machine"] && Enum.find(Issues.machines(), &(params["machine"] in [&1.id, &1.name]))

    with true <- !((params["service"] && !service) || (params["machine"] && !machine)),
         {:ok, from} <- time(params["from"], nil),
         {:ok, to} <- time(params["to"], nil),
         {:ok, at} <- cursor_at(params) do
      n = limit(params, 500)

      Logs.list(
        q: params["q"],
        level: params["level"],
        service: service && service.id,
        machine: machine && machine.id,
        from: from,
        to: to,
        before: at,
        limit: n + 1
      )
      |> cut(n, &tkey(&1.at, &1.id))
      |> mapped(fn l ->
        %{
          t: l.at,
          level: l.level,
          msg: l.msg,
          fields: l.fields,
          machine: l.machine.name,
          service: l.service && l.service.slug
        }
      end)
    else
      {:error, _, _} = e -> e
      _ -> nil
    end
  end

  defp issue_state(nil), do: {:ok, fn _ -> dynamic([i], is_nil(i.closed_at)) end}
  defp issue_state("all"), do: {:ok, fn _ -> dynamic([], true) end}
  defp issue_state("closed"), do: {:ok, fn _ -> dynamic([i], not is_nil(i.closed_at)) end}

  defp issue_state("open"),
    do:
      {:ok,
       fn now ->
         dynamic(
           [i],
           is_nil(i.closed_at) and (is_nil(i.snoozed_until) or i.snoozed_until <= ^now)
         )
       end}

  defp issue_state("snoozed"),
    do: {:ok, fn now -> dynamic([i], is_nil(i.closed_at) and i.snoozed_until > ^now) end}

  defp issue_state(_),
    do: {:error, "bad_state", "state is open, snoozed, closed or all."}

  defp all_of(filters),
    do:
      Enum.reduce(Enum.filter(filters, & &1), dynamic([], true), fn d, acc ->
        dynamic([], ^acc and ^d)
      end)

  defp like_text(q) when is_binary(q) do
    case String.trim(q) do
      "" -> nil
      q -> "%" <> String.replace(q, ["\\", "%", "_"], &("\\" <> &1)) <> "%"
    end
  end

  defp like_text(_), do: nil

  defp after_time(nil, _), do: dynamic([], true)

  defp after_time({at, id}, field),
    do:
      dynamic(
        [x],
        field(x, ^field) < ^at or (field(x, ^field) == ^at and x.id < ^id)
      )

  defp like?(params, fields) do
    case String.downcase(String.trim(to_string(params["q"] || ""))) do
      "" ->
        true

      q ->
        Enum.any?(fields, &(is_binary(&1) and String.contains?(String.downcase(&1), q)))
    end
  end

  defp within?(at, from, to),
    do:
      (is_nil(from) or DateTime.compare(at, from) != :lt) and
        (is_nil(to) or DateTime.compare(at, to) != :gt)

  defp times(params) do
    with {:ok, from} <- time(params["from"], nil), {:ok, to} <- time(params["to"], nil) do
      {:ok, from, to}
    else
      _ -> {:error, "bad_time", "from and to are times, in RFC 3339."}
    end
  end

  defp down(text), do: String.downcase(text || "")

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(20, "0")

  defp tkey(at, id),
    do: pad(if(at, do: DateTime.to_unix(at, :microsecond), else: 0)) <> to_string(id)

  defp page(items, params, key, dir \\ :asc) do
    case cursor(params) do
      {:ok, after_key} ->
        sorted = Enum.sort_by(items, key, dir)

        rest =
          if after_key,
            do: Enum.drop_while(sorted, &(not after?(key.(&1), after_key, dir))),
            else: sorted

        cut(rest, limit(params), key)

      error ->
        error
    end
  end

  defp ordered(items, params) do
    case page(Enum.with_index(items), params, &pad(elem(&1, 1))) do
      %{items: items} = page -> %{page | items: Enum.map(items, &elem(&1, 0))}
      error -> error
    end
  end

  defp after?(key, cursor, :asc), do: key > cursor
  defp after?(key, cursor, :desc), do: key < cursor

  defp cut(rows, n, key) do
    {items, more} = Enum.split(rows, n)

    %{
      items: items,
      next:
        if(more == [], do: nil, else: Base.url_encode64(key.(List.last(items)), padding: false))
    }
  end

  defp mapped(%{items: items} = page, f), do: %{page | items: Enum.map(items, f)}
  defp mapped(other, _), do: other

  defp cursor(%{"cursor" => text}) when is_binary(text) and text != "" do
    with {:ok, key} <- Base.url_decode64(text, padding: false),
         true <- String.valid?(key) do
      {:ok, key}
    else
      _ -> {:error, "bad_cursor", "cursor is the next value of an earlier answer."}
    end
  end

  defp cursor(_), do: {:ok, nil}

  defp cursor_id(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> Ecto.UUID.cast(id)
    end
  end

  defp cursor_at(params) do
    case cursor(params) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, <<micro::binary-size(20), id::binary>>} ->
        with {n, ""} <- Integer.parse(micro),
             {:ok, id} <- cursor_id(id),
             {:ok, at} <- DateTime.from_unix(n, :microsecond) do
          {:ok, {at, id}}
        else
          _ -> {:error, "bad_cursor", "cursor is the next value of an earlier answer."}
        end

      {:ok, _} ->
        {:error, "bad_cursor", "cursor is the next value of an earlier answer."}

      error ->
        error
    end
  end

  defp time(nil, default), do: {:ok, default}

  defp time(text, _) when is_binary(text) do
    with {:ok, at, _} <- DateTime.from_iso8601(text), do: {:ok, at}
  end

  defp time(_, _), do: :error

  def rules, do: Dokkit.Alerts.rules()

  defp found(f),
    do: %{
      id: f.id,
      kind: f.kind,
      name: f.key,
      detail: f.detail,
      machine: f.machine.name,
      origin: f.origin,
      why: f.why
    }

  defp issue(%Issue{} = i) do
    %{
      id: i.id,
      short_id: Issue.short_id(i),
      kind: i.kind,
      state: i.state,
      soon: i.soon,
      title: i.title,
      note: i.check && i.check.note,
      count: i.count,
      since: i.since,
      snoozed_until: i.snoozed_until,
      acknowledged_at: i.acknowledged_at,
      machine: i.machine.name,
      service: i.service_id,
      alert: alert_view(List.first(i.alerts)),
      alerts: Enum.map(i.alerts, &alert_view/1)
    }
  end

  defp alert_view(nil), do: nil
  defp alert_view(a), do: %{channel: a.channel, status: a.status}

  defp service_row(s, m) do
    %{
      id: s.id,
      slug: s.slug,
      name: s.name,
      kind: s.kind,
      environment: s.environment,
      state: if(s.watched, do: s.state, else: :unwatched),
      note: s.note,
      version: s.version,
      held: s.held,
      machine: m.name
    }
  end

  defp run(r),
    do:
      Map.take(r, [
        :run,
        :result,
        :started_at,
        :finished_at,
        :exit_code,
        :duration_ms,
        :done,
        :total,
        :tail
      ])
end
