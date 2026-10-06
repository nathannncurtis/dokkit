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
              :error
            ]

  plug :scope, "read-logs" when action in [:logs]
  plug :scope, "act" when action in [:snooze, :unsnooze, :acknowledge, :run_task]

  def inbox(conn, _), do: json(conn, Read.inbox())
  def issues(conn, _), do: list(conn, Read.issues())
  def machines(conn, _), do: list(conn, Read.machines())
  def services(conn, params), do: list(conn, Read.services(params))
  def jobs(conn, _), do: list(conn, Read.jobs())
  def deploys(conn, _), do: list(conn, Read.deploys())
  def errors(conn, _), do: list(conn, Read.errors())

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
