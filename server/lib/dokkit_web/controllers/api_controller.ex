defmodule DokkitWeb.ApiController do
  @moduledoc "The read and act calls of spec/api.md, for a user token."
  use DokkitWeb, :controller
  alias Dokkit.{Issues, Keys, Read}

  plug :token
  plug :scope

  def inbox(conn, _), do: json(conn, Read.inbox())
  def issues(conn, _), do: list(conn, Read.issues())
  def machines(conn, _), do: list(conn, Read.machines())
  def services(conn, params), do: list(conn, Read.services(params))
  def jobs(conn, _), do: list(conn, Read.jobs())
  def deploys(conn, _), do: list(conn, Read.deploys())
  def errors(conn, _), do: list(conn, Read.errors())
  def rules(conn, _), do: list(conn, Read.rules())

  def keys(conn, _), do: list(conn, Read.keys())
  def users(conn, _), do: list(conn, Read.users())

  @scopes ~w(read read-logs act admin)

  @doc "Makes a token for a script, a key for an app, or a one-use token to enrol a machine. Shown once."
  def add_key(conn, %{"kind" => "user"} = p) do
    scopes = for s <- List.wrap(p["scopes"]), s in @scopes, do: s

    if scopes == [] or blank?(p["label"]),
      do: fail(conn, 422, "bad_key", "A token needs a label and scopes."),
      else:
        minted(
          conn,
          Keys.mint(:user, %{label: p["label"], scopes: scopes, user_id: conn.assigns.key.user_id})
        )
  end

  def add_key(conn, %{"kind" => "app", "service" => id}) do
    case Dokkit.Estate.service(id) do
      nil -> missing(conn)
      service -> minted(conn, Keys.mint(:app, %{service_id: service.id}))
    end
  end

  def add_key(conn, %{"kind" => "enrol"} = p) do
    expires = DateTime.add(DateTime.utc_now(), 3600)
    label = if is_binary(p["machine"]) and p["machine"] != "", do: String.trim(p["machine"])
    minted(conn, Keys.mint(:enrol, %{expires_at: expires, label: label}))
  end

  def add_key(conn, _),
    do:
      fail(
        conn,
        422,
        "bad_key",
        "kind is user with label and scopes, app with service, or enrol."
      )

  defp minted(conn, {text, key}), do: json(conn, %{id: key.id, key: text})
  defp blank?(text), do: not is_binary(text) or String.trim(text) == ""

  def revoke_key(conn, %{"id" => id}) do
    Keys.revoke(id)
    json(conn, %{ok: true})
  end

  def add_user(conn, params) do
    case Dokkit.Accounts.add(params["name"], params["role"], params["password"]) do
      {:ok, user} -> json(conn, Map.take(user, [:id, :name, :role]))
      {:error, why} -> fail(conn, 422, "bad_person", why)
    end
  end

  def remove_user(conn, %{"id" => id}) do
    case Dokkit.Accounts.remove(id, %Dokkit.User{}) do
      :ok -> json(conn, %{ok: true})
      {:error, why} -> fail(conn, 422, "bad_person", why)
    end
  end

  def versions(conn, _), do: json(conn, %{items: Read.versions(), apps: Read.apps(), next: nil})
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

  def watch(conn, %{"id" => id}), do: change(conn, id, &Dokkit.Estate.set_watched(&1, true))
  def unwatch(conn, %{"id" => id}), do: change(conn, id, &Dokkit.Estate.set_watched(&1, false))

  def hold(conn, %{"id" => id} = p),
    do: change(conn, id, &Dokkit.Estate.set(&1, :held, p["version"]))

  def restart(conn, %{"id" => id} = p),
    do: change(conn, id, &Dokkit.Estate.set(&1, :restart, p["allow"]))

  def checks(conn, %{"id" => id} = params) do
    with %{} = service <- Dokkit.Estate.service(id),
         {:ok, _} <- Dokkit.Estate.set_checks(service, params["checks"]) do
      json(conn, Read.service(id))
    else
      nil -> missing(conn)
      {:error, why} -> fail(conn, 422, "bad_checks", why)
    end
  end

  defp change(conn, id, act) do
    case Dokkit.Estate.service(id) do
      nil ->
        missing(conn)

      service ->
        act.(service)
        json(conn, Read.service(id))
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

  def error(conn, %{"id" => id}), do: one(conn, Read.error(id))

  def tasks(conn, _), do: list(conn, Read.tasks())
  def task_runs(conn, _), do: list(conn, Read.task_runs())

  def run_task(conn, %{"id" => id}) do
    case Dokkit.Tasks.run(id, "token " <> (conn.assigns.key.label || "")) do
      nil -> missing(conn)
      run -> json(conn, %{run: run.id})
    end
  end

  def service(conn, %{"id" => id}), do: one(conn, Read.service(id))

  def series(conn, %{"id" => id} = params), do: one(conn, Read.series(id, params))

  def runs(conn, %{"id" => id}), do: list(conn, Read.runs(id))
  def logs(conn, params), do: list(conn, Read.logs(params))

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

  defp list(conn, nil), do: missing(conn)
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

  # What a call needs follows from the call: reading needs read, log contents need
  # read-logs, keys and people need admin, and anything else changes something.
  defp scope(conn, _) do
    scope =
      case {conn.method, Enum.at(conn.path_info, 2)} do
        {_, area} when area in ["keys", "users"] -> "admin"
        {"GET", "logs"} -> "read-logs"
        {"GET", _} -> "read"
        _ -> "act"
      end

    if scope in conn.assigns.key.scopes,
      do: conn,
      else: conn |> fail(403, "no_scope", "This token may not #{scope}.") |> halt()
  end
end
