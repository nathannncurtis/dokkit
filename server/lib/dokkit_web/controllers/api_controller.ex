defmodule DokkitWeb.ApiController do
  @moduledoc "The read and act calls of spec/api.md, for a user token."
  use DokkitWeb, :controller
  alias Dokkit.{Issues, Keys, Read}

  plug :token

  plug :scope,
       "read"
       when action in [
              :inbox,
              :machines,
              :services,
              :service,
              :issues,
              :jobs,
              :runs,
              :tasks,
              :task_runs,
              :deploys,
              :errors,
              :error,
              :series,
              :rules,
              :machine,
              :versions,
              :issue,
              :proposals
            ]

  plug :scope, "read-logs" when action in [:logs]

  plug :scope,
       "act"
       when action in [
              :snooze,
              :unsnooze,
              :acknowledge,
              :run_task,
              :note,
              :bulk,
              :routing,
              :accept,
              :dismiss,
              :add_rule,
              :update_rule,
              :delete_rule
            ]

  def inbox(conn, _), do: json(conn, Read.inbox())
  def issues(conn, _), do: list(conn, Read.issues())
  def machines(conn, _), do: list(conn, Read.machines())
  def services(conn, params), do: list(conn, Read.services(params))
  def jobs(conn, _), do: list(conn, Read.jobs())
  def deploys(conn, _), do: list(conn, Read.deploys())
  def errors(conn, _), do: list(conn, Read.errors())
  def rules(conn, _), do: list(conn, Read.rules())

  def versions(conn, _), do: list(conn, Read.versions())
  def proposals(conn, _), do: list(conn, Read.proposals())
  def machine(conn, %{"id" => id}), do: one(conn, Read.machine(id))
  def issue(conn, %{"id" => id}), do: one(conn, Read.one_issue(id))

  def note(conn, %{"id" => id, "text" => text}) when is_binary(text) and text != "" do
    case Issues.note(id, text, "token " <> (conn.assigns.key.label || "")) do
      nil -> missing(conn)
      _ -> json(conn, %{ok: true})
    end
  end

  def note(conn, _), do: fail(conn, 422, "bad_note", "Needs text.")

  def bulk(conn, %{"ids" => ids, "action" => action} = params) when is_list(ids) do
    case {action, seconds_until(params["until"])} do
      {"snooze", {:ok, seconds}} -> Issues.snooze(ids, seconds)
      {"unsnooze", _} -> Issues.unsnooze(ids)
      {"acknowledge", _} -> Issues.acknowledge(ids)
      _ -> nil
    end
    |> case do
      nil ->
        fail(conn, 422, "bad_action", "action is snooze with until, unsnooze or acknowledge.")

      _ ->
        json(conn, %{ok: true})
    end
  end

  def bulk(conn, _), do: fail(conn, 422, "bad_action", "Needs ids and action.")

  def routing(conn, %{"id" => id} = params) do
    case Dokkit.Estate.service(id) do
      nil ->
        missing(conn)

      service ->
        s = Dokkit.Estate.set_routing(service, params)
        json(conn, %{down: s.route_down, degraded: s.route_degraded})
    end
  end

  # A task is a command a machine would run, so it is accepted by a person in the interface.
  def accept(conn, %{"id" => id}), do: found(conn, id, &Dokkit.Found.watch/1)
  def dismiss(conn, %{"id" => id}), do: found(conn, id, &Dokkit.Found.dismiss/1)

  defp found(conn, id, act) do
    if Enum.any?(Dokkit.Found.list(), &(&1.id == id)) do
      act.([id])
      json(conn, %{ok: true})
    else
      missing(conn)
    end
  end

  def add_rule(conn, params), do: json(conn, List.last(Dokkit.Alerts.add_rule(params)))

  def update_rule(conn, %{"id" => id} = params) do
    case Enum.find(Dokkit.Alerts.update_rule(id, params), &(&1["id"] == id)) do
      nil -> missing(conn)
      rule -> json(conn, rule)
    end
  end

  def delete_rule(conn, %{"id" => id}) do
    Dokkit.Alerts.delete_rule(id)
    json(conn, %{ok: true})
  end

  defp one(conn, nil), do: missing(conn)
  defp one(conn, thing), do: json(conn, thing)

  def error(conn, %{"id" => id}) do
    case Read.error(id) do
      nil -> missing(conn)
      error -> json(conn, error)
    end
  end

  def tasks(conn, _), do: list(conn, Read.tasks())
  def task_runs(conn, _), do: list(conn, Read.task_runs())

  def run_task(conn, %{"id" => id}) do
    case Dokkit.Tasks.run(id, "token " <> (conn.assigns.key.label || "")) do
      nil -> missing(conn)
      run -> json(conn, %{run: run.id})
    end
  end

  def service(conn, %{"id" => id}) do
    case Read.service(id) do
      nil -> missing(conn)
      service -> json(conn, service)
    end
  end

  def series(conn, %{"id" => id} = params) do
    case Read.series(id, params) do
      nil -> missing(conn)
      series -> json(conn, series)
    end
  end

  def runs(conn, %{"id" => id}) do
    case Read.runs(id) do
      nil -> missing(conn)
      runs -> list(conn, runs)
    end
  end

  def logs(conn, params) do
    case Read.logs(params) do
      nil -> missing(conn)
      lines -> list(conn, lines)
    end
  end

  def snooze(conn, %{"id" => id, "until" => until}) do
    case seconds_until(until) do
      {:ok, seconds} ->
        Issues.snooze(id, seconds)
        json(conn, %{ok: true})

      :error ->
        fail(conn, 422, "bad_time", "until must be a time in the future, in RFC 3339.")
    end
  end

  def snooze(conn, _), do: fail(conn, 422, "bad_time", "Needs until.")

  def unsnooze(conn, %{"id" => id}) do
    Issues.unsnooze(id)
    json(conn, %{ok: true})
  end

  def acknowledge(conn, %{"id" => id}) do
    Issues.acknowledge(id)
    json(conn, %{ok: true})
  end

  def seconds_until(text) do
    with true <- is_binary(text),
         {:ok, at, _} <- DateTime.from_iso8601(text),
         seconds when seconds > 0 <- DateTime.diff(at, DateTime.utc_now()) do
      {:ok, seconds}
    else
      _ -> :error
    end
  end

  defp list(conn, items), do: json(conn, %{items: items, next: nil})
  defp missing(conn), do: fail(conn, 404, "not_found", "No such thing.")

  def token(conn, _) do
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
end
