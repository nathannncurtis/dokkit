defmodule DokkitWeb.ApiController do
  @moduledoc "The read and act calls of spec/api.md, for a user token."
  use DokkitWeb, :controller
  alias Dokkit.{Estate, Issue, Issues, Keys, Logs}

  plug :token

  plug :scope,
       "read" when action in [:inbox, :machines, :services, :service, :issues, :jobs, :runs]

  plug :scope, "read-logs" when action in [:logs]
  plug :scope, "act" when action in [:snooze, :unsnooze, :acknowledge]

  def inbox(conn, _) do
    json(conn, %{
      needs_you: Enum.map(Issues.open_list(), &issue/1),
      snoozed: Enum.map(Issues.snoozed_list(), &issue/1)
    })
  end

  def issues(conn, _),
    do: list(conn, Enum.map(Issues.open_list() ++ Issues.snoozed_list(), &issue/1))

  def machines(conn, _) do
    list(
      conn,
      for(
        m <- Issues.machines(),
        do:
          Map.take(m, [:id, :name, :kind, :os, :last_seen_at, :down])
          |> Map.put(:needs_a_look, m.bad)
      )
    )
  end

  def services(conn, params) do
    q = String.downcase(params["q"] || "")

    items =
      for m <- Estate.machines(),
          s <- m.services,
          params["machine"] in [nil, m.id, m.name],
          q == "" or String.contains?(String.downcase(s.name <> " " <> s.slug), q),
          do: service_row(s, m)

    list(conn, items)
  end

  def service(conn, %{"id" => id}) do
    case Estate.service(id) do
      nil ->
        missing(conn)

      s ->
        open = Estate.open_issue(s)

        json(
          conn,
          service_row(s, s.machine)
          |> Map.merge(%{
            checks:
              for(
                c <- s.checks,
                do:
                  Map.take(c, [:name, :type, :state, :note, :value, :checked_at, :source, :config])
              ),
            routing: %{down: s.route_down, degraded: s.route_degraded},
            open_issue:
              open && issue(Dokkit.Repo.preload(open, [:machine, :service, :check, :alert]))
          })
        )
    end
  end

  def jobs(conn, _) do
    items =
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

    list(conn, items)
  end

  def runs(conn, %{"id" => id}) do
    case Estate.service(id) do
      nil -> missing(conn)
      s -> list(conn, Enum.map(Estate.runs(s, 100), &run/1))
    end
  end

  def logs(conn, params) do
    service = params["service"] && Estate.service(params["service"])

    if params["service"] && !service do
      missing(conn)
    else
      lines =
        Logs.list(
          q: params["q"],
          level: params["level"],
          service: service && service.id,
          limit: 500
        )

      list(
        conn,
        for l <- lines do
          %{
            t: l.at,
            level: l.level,
            msg: l.msg,
            fields: l.fields,
            machine: l.machine.name,
            service: l.service && l.service.slug
          }
        end
      )
    end
  end

  def snooze(conn, %{"id" => id, "until" => until}) do
    with {:ok, at, _} <- DateTime.from_iso8601(until),
         seconds when seconds > 0 <- DateTime.diff(at, DateTime.utc_now()) do
      Issues.snooze(id, seconds)
      json(conn, %{ok: true})
    else
      _ -> fail(conn, 422, "bad_time", "until must be a time in the future, in RFC 3339.")
    end
  end

  def snooze(conn, _), do: fail(conn, 422, "bad_time", "Needs until.")

  def unsnooze(conn, %{"id" => id}), do: Issues.unsnooze(id) && json(conn, %{ok: true})
  def acknowledge(conn, %{"id" => id}), do: Issues.acknowledge(id) && json(conn, %{ok: true})

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
      state: s.state,
      note: s.note,
      version: s.version,
      machine: m.name
    }
  end

  defp run(r) do
    Map.take(r, [:run, :result, :started_at, :finished_at, :exit_code, :duration_ms, :tail])
  end

  defp list(conn, items), do: json(conn, %{items: items, next: nil})
  defp missing(conn), do: fail(conn, 404, "not_found", "No such thing.")

  defp token(conn, _) do
    with ["Bearer " <> text] <- get_req_header(conn, "authorization"),
         {:ok, key} <- Keys.verify(text, :user) do
      Keys.used(key)
      assign(conn, :key, key)
    else
      _ -> conn |> fail(401, "bad_key", "Missing or bad key.") |> halt()
    end
  end

  defp scope(conn, scope) do
    if scope in conn.assigns.key.scopes,
      do: conn,
      else: conn |> fail(403, "no_scope", "This token may not #{scope}.") |> halt()
  end

  defp fail(conn, status, code, message) do
    conn |> put_status(status) |> json(%{error: %{code: code, message: message}})
  end
end
