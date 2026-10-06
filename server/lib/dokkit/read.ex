defmodule Dokkit.Read do
  @moduledoc "What the API and the MCP answer with, as plain maps."
  import Ecto.Query, only: [from: 2]
  alias Dokkit.{Estate, Issue, Issues, Logs, Repo}

  def inbox do
    %{
      needs_you: Enum.map(Issues.open_list(), &issue/1),
      snoozed: Enum.map(Issues.snoozed_list(), &issue/1)
    }
  end

  def issues, do: Enum.map(Issues.open_list() ++ Issues.snoozed_list(), &issue/1)

  def machines do
    for m <- Issues.machines() do
      m
      |> Map.take([:id, :name, :kind, :os, :last_seen_at, :down])
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

  def machine(id) do
    with %{} = m <- Enum.find(machines(), &(&1.id == id)) do
      config = Dokkit.Alerts.config()

      Map.merge(m, %{
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
      i = Repo.preload(i, [:machine, :service, :check, :alert])
      Map.merge(issue(i), %{closed_at: i.closed_at, notes: i.notes})
    else
      _ -> nil
    end
  end

  @doc "What waits to be accepted: found things, and tasks a file offers."
  def proposals do
    found =
      for f <- Dokkit.Found.list(),
          do: %{id: f.id, kind: f.kind, name: f.key, detail: f.detail, machine: f.machine.name}

    tasks =
      for t <- Dokkit.Tasks.waiting(),
          do: %{id: t.id, kind: "task", name: t.name, command: t.command, machine: t.machine.name}

    found ++ tasks
  end

  def services(params) do
    q = String.downcase(params["q"] || "")

    for m <- Estate.machines(),
        s <- m.services,
        params["machine"] in [nil, m.id, m.name],
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
        routing: %{down: s.route_down, degraded: s.route_degraded},
        restart: s.restart,
        stats: s.stats,
        stats_at: s.stats_at,
        open_issue: open && issue(Repo.preload(open, [:machine, :service, :check, :alert]))
      })
    end
  end

  def jobs do
    for j <- Estate.jobs() do
      %{
        id: j.service.id,
        name: Dokkit.Intake.label(j.service, j.check.name),
        machine: j.machine.name,
        state: j.check.state,
        schedule: j.check.config["schedule"],
        last_run: j.last && run(j.last),
        last_good_run: j.good,
        next_expected: Estate.next_expected(j.check)
      }
    end
  end

  def runs(id) do
    with %{} = s <- Estate.service(id), do: Enum.map(Estate.runs(s, 100), &run/1)
  end

  @log_keys [:tail, :output, :message, :notes]

  @doc "The answer without job output, task output, error messages and issue notes, for a token that may not read logs."
  def without_logs(%{__struct__: _} = x), do: x

  def without_logs(%{} = m),
    do: m |> Map.drop(@log_keys) |> Map.new(fn {k, v} -> {k, without_logs(v)} end)

  def without_logs(list) when is_list(list), do: Enum.map(list, &without_logs/1)
  def without_logs(x), do: x

  @doc "nil when a service or machine is named and does not exist, or a time is not one."
  def logs(params) do
    service = params["service"] && Estate.service(params["service"])

    machine =
      params["machine"] && Enum.find(Issues.machines(), &(params["machine"] in [&1.id, &1.name]))

    with true <- !((params["service"] && !service) || (params["machine"] && !machine)),
         {:ok, from} <- time(params["from"], nil),
         {:ok, to} <- time(params["to"], nil) do
      for l <-
            Logs.list(
              q: params["q"],
              level: params["level"],
              service: service && service.id,
              machine: machine && machine.id,
              from: from,
              to: to,
              limit: 500
            ) do
        %{
          t: l.at,
          level: l.level,
          msg: l.msg,
          fields: l.fields,
          machine: l.machine.name,
          service: l.service && l.service.slug
        }
      end
    else
      _ -> nil
    end
  end

  def deploys(opts \\ []) do
    for d <- Dokkit.Deploys.list(opts) do
      d
      |> Map.take([:from, :version, :commit, :by, :how, :at])
      |> Map.merge(%{
        service: d.service_id,
        name: d.service.name,
        machine: d.service.machine.name
      })
    end
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
                preload: [:machine, :service, :check, :alert]
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

  def error(id) do
    with %{group: group, latest: latest} <- Dokkit.Errors.get(id) do
      Map.merge(error_group(group), %{
        frames: (latest && latest.frames) || [],
        tags: (latest && latest.tags) || %{},
        message: latest && latest.message
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
    now = DateTime.utc_now()

    with %{} = s <- Estate.service(id),
         {:ok, to} <- time(params["to"], now),
         {:ok, from} <- time(params["from"], DateTime.add(to, -86_400)),
         :lt <- DateTime.compare(from, to) do
      points =
        case Integer.parse(params["points"] || "") do
          {n, ""} when n in 1..500 -> n
          _ -> 24
        end

      case params["metric"] do
        nil -> %{metrics: Dokkit.Numbers.names(s.id)}
        name -> %{metric: name, points: Dokkit.Numbers.series(s.id, name, from, to, points)}
      end
    else
      _ -> nil
    end
  end

  defp time(nil, default), do: {:ok, default}

  defp time(text, _) do
    with {:ok, at, _} <- DateTime.from_iso8601(text), do: {:ok, at}
  end

  def rules, do: Dokkit.Alerts.rules()

  def tasks do
    for %{task: t, last: last} <- Dokkit.Tasks.accepted() do
      %{
        id: t.id,
        name: t.name,
        command: t.command,
        machine: t.machine.name,
        as: Dokkit.Tasks.account(t),
        last_run: last && task_run(last)
      }
    end
  end

  def task_runs do
    for r <- Dokkit.Tasks.runs(),
        do: Map.merge(task_run(r), %{task: r.task.name, machine: r.task.machine.name})
  end

  defp task_run(r),
    do:
      Map.take(r, [:id, :state, :by, :exit_code, :duration_ms, :output, :started_at, :finished_at])

  defp issue(%Issue{} = i) do
    %{
      id: i.id,
      short_id: Issue.short_id(i),
      kind: i.kind,
      state: i.state,
      title: i.title,
      note: i.check && i.check.note,
      count: i.count,
      since: i.since,
      snoozed_until: i.snoozed_until,
      acknowledged_at: i.acknowledged_at,
      machine: i.machine.name,
      service: i.service_id,
      alert: i.alert && %{channel: i.alert.channel, status: i.alert.status}
    }
  end

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
    do: Map.take(r, [:run, :result, :started_at, :finished_at, :exit_code, :duration_ms, :tail])
end
