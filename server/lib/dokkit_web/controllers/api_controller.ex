defmodule DokkitWeb.ApiController do
  @moduledoc "The read and act calls of spec/api.md, for a user token."
  use DokkitWeb, :controller
  alias Dokkit.{Issues, Keys, Read}

  plug :token
  plug :scope

  def inbox(conn, _), do: json(conn, clean(conn, Read.inbox()))
  def day(conn, params), do: reply(conn, the_day(params))

  def the_day(%{"to" => text}) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, to, _} -> Read.day(to)
      _ -> {:error, "bad_time", "to must be a time, in RFC 3339."}
    end
  end

  def the_day(_), do: Read.day()

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

  # The functions below hold the logic of a call that is more than one line. The API and the
  # MCP both use them. They return data, or {:error, code, message}.
  defp not_found, do: {:error, "not_found", "No such thing."}

  defp reply(conn, {:error, "not_found", _}), do: missing(conn)
  defp reply(conn, {:error, code, message}), do: fail(conn, 422, code, message)
  defp reply(conn, data), do: json(conn, clean(conn, data))

  @doc "Makes a token for a script, a key for an app, or a one-use token to enrol a machine. Shown once."
  def make_key(%{"kind" => "user"} = p, %{user_id: user_id, scopes: held}) do
    scopes = for s <- List.wrap(p["scopes"]), s in @scopes, do: s

    cond do
      scopes == [] or blank?(p["label"]) ->
        {:error, "bad_key", "A token needs a label and scopes."}

      "admin" in scopes ->
        {:error, "bad_key", "A token with admin is made in Settings, not here."}

      scopes -- held != [] ->
        {:error, "bad_key", "A token can only make a token with scopes it has itself."}

      true ->
        minted(Keys.mint(:user, %{label: p["label"], scopes: scopes, user_id: user_id}))
    end
  end

  def make_key(%{"kind" => "app", "service" => id}, _) do
    case Dokkit.Estate.service(id) do
      nil -> not_found()
      service -> minted(Keys.mint(:app, %{service_id: service.id}))
    end
  end

  def make_key(%{"kind" => "enrol"} = p, _) do
    expires = DateTime.add(DateTime.utc_now(), 3600)
    label = if is_binary(p["machine"]) and p["machine"] != "", do: String.trim(p["machine"])
    minted(Keys.mint(:enrol, %{expires_at: expires, label: label}))
  end

  def make_key(_, _),
    do: {:error, "bad_key", "kind is user with label and scopes, app with service, or enrol."}

  defp minted({text, key}), do: %{id: key.id, key: text}
  defp blank?(text), do: not is_binary(text) or String.trim(text) == ""

  def add_key(conn, p), do: reply(conn, make_key(p, conn.assigns.key))

  def drop_key(id) do
    Keys.revoke(id)
    %{ok: true}
  end

  def revoke_key(conn, %{"id" => id}), do: reply(conn, drop_key(id))

  def new_person(params) do
    case Dokkit.Accounts.add(params["name"], params["role"], params["password"]) do
      {:ok, user} -> Map.take(user, [:id, :name, :role])
      {:error, why} -> {:error, "bad_person", why}
    end
  end

  def drop_person(id) do
    case Dokkit.Accounts.remove(id, %Dokkit.User{}) do
      :ok -> %{ok: true}
      {:error, why} -> {:error, "bad_person", why}
    end
  end

  def add_user(conn, params), do: reply(conn, new_person(params))
  def remove_user(conn, %{"id" => id}), do: reply(conn, drop_person(id))

  def versions(conn, _),
    do:
      json(conn, %{items: Read.versions(), apps: Read.apps(), program: Read.program(), next: nil})

  def proposals(conn, _), do: list(conn, Read.proposals())
  def machine(conn, %{"id" => id}), do: one(conn, Read.machine(id))
  def issue(conn, %{"id" => id}), do: one(conn, Read.one_issue(id))

  def add_note(%{"id" => id, "text" => text}, who) when is_binary(text) and text != "" do
    if Issues.note(id, text, who), do: %{ok: true}, else: not_found()
  end

  def add_note(_, _), do: {:error, "bad_note", "Needs text."}

  def note(conn, params),
    do: reply(conn, add_note(params, "token " <> (conn.assigns.key.label || "")))

  def bulk_issues(%{"ids" => ids, "action" => action} = params) when is_list(ids) do
    case {action, seconds_until(params["until"])} do
      {"snooze", {:ok, seconds}} -> Issues.snooze(ids, seconds)
      {"unsnooze", _} -> Issues.unsnooze(ids)
      {"acknowledge", _} -> Issues.acknowledge(ids)
      _ -> nil
    end
    |> case do
      nil -> {:error, "bad_action", "action is snooze with until, unsnooze or acknowledge."}
      _ -> %{ok: true}
    end
  end

  def bulk_issues(_), do: {:error, "bad_action", "Needs ids and action."}

  def bulk(conn, params), do: reply(conn, bulk_issues(params))

  def set_routing(%{"id" => id} = params) do
    case Dokkit.Estate.service(id) do
      nil ->
        not_found()

      service ->
        s = Dokkit.Estate.set_routing(service, params)
        %{down: s.route_down, degraded: s.route_degraded, night: s.night}
    end
  end

  def routing(conn, params), do: reply(conn, set_routing(params))

  @doc "Changes a service, then returns it as the API shows it."
  def change(id, act) do
    case Dokkit.Estate.service(id) do
      nil ->
        not_found()

      service ->
        act.(service)
        Read.service(id)
    end
  end

  def set_held(id, version), do: change(id, &Dokkit.Estate.set(&1, :held, version))
  def set_restart(id, allow), do: change(id, &Dokkit.Estate.set(&1, :restart, allow))

  def watch(conn, %{"id" => id}),
    do: reply(conn, change(id, &Dokkit.Estate.set_watched(&1, true)))

  def unwatch(conn, %{"id" => id}),
    do: reply(conn, change(id, &Dokkit.Estate.set_watched(&1, false)))

  def hold(conn, %{"id" => id} = p), do: reply(conn, set_held(id, p["version"]))
  def restart(conn, %{"id" => id} = p), do: reply(conn, set_restart(id, p["allow"]))

  def set_service_checks(%{"id" => id} = params) do
    with %{} = service <- Dokkit.Estate.service(id),
         {:ok, _} <- Dokkit.Estate.set_checks(service, params["checks"]) do
      Read.service(id)
    else
      nil -> not_found()
      {:error, why} -> {:error, "bad_checks", why}
    end
  end

  def checks(conn, params), do: reply(conn, set_service_checks(params))

  # A found service or port. A task is a command a machine would run, so it goes through accept_task.
  def accept(conn, %{"id" => id}), do: reply(conn, found(id, &Dokkit.Found.watch/1))
  def dismiss(conn, %{"id" => id}), do: reply(conn, found(id, &Dokkit.Found.dismiss/1))

  def found(id, act) do
    if Enum.any?(Dokkit.Found.list(), &(&1.id == id)) do
      act.([id])
      %{ok: true}
    else
      not_found()
    end
  end

  def new_rule(params) do
    case Dokkit.Alerts.rule_error(params) do
      nil -> List.last(Dokkit.Alerts.add_rule(params))
      why -> {:error, "bad_rule", why}
    end
  end

  def edit_rule(%{"id" => id} = params) do
    case Dokkit.Alerts.rule_error(params) do
      nil ->
        Enum.find(Dokkit.Alerts.update_rule(id, params), &(&1["id"] == id)) || not_found()

      why ->
        {:error, "bad_rule", why}
    end
  end

  def drop_rule(id) do
    Dokkit.Alerts.delete_rule(id)
    %{ok: true}
  end

  def add_rule(conn, params), do: reply(conn, new_rule(params))
  def update_rule(conn, params), do: reply(conn, edit_rule(params))
  def delete_rule(conn, %{"id" => id}), do: reply(conn, drop_rule(id))

  def set_keep(id, keep) when is_boolean(keep),
    do: change(id, &Dokkit.Estate.set(&1, :keep_messages, keep))

  def set_keep(_, _), do: {:error, "bad_keep", "keep is true or false."}

  def keep_messages(conn, %{"id" => id} = p), do: reply(conn, set_keep(id, p["keep"]))

  @job_texts ~w(name machine schedule grace max_runtime)

  def new_job(params) do
    with true <- texts?(params, @job_texts),
         {:ok, %{service: s, key: key}} <- Dokkit.Estate.add_job(params) do
      ping =
        for e <- ~w(start ok fail), into: %{}, do: {e, Dokkit.Intake.ping_url(key, s.slug, e)}

      %{id: s.id, name: s.name, key: key, ping: ping}
    else
      false -> {:error, "bad_job", "Every field is text."}
      {:error, why} -> {:error, "bad_job", why}
    end
  end

  def add_job(conn, params), do: reply(conn, new_job(params))

  def new_app(params) do
    with true <- texts?(params, ~w(name)),
         {:ok, %{service: s, key: key}} <- Dokkit.Estate.add_app(params) do
      %{id: s.id, name: s.name, slug: s.slug, key: key}
    else
      false -> {:error, "bad_app", "The name is text."}
      {:error, why} -> {:error, "bad_app", why}
    end
  end

  def add_app(conn, params), do: reply(conn, new_app(params))

  def job_timing(%{"id" => id} = params) do
    with true <- texts?(params, ~w(grace max_runtime)),
         %{} = service <- Dokkit.Estate.service(id),
         %{} = job <- Enum.find(service.checks, &(&1.type == :job)),
         {:ok, _} <- Dokkit.Estate.set_job_timing(job, params) do
      Enum.find(Read.jobs(), &(&1.id == id))
    else
      nil -> not_found()
      false -> {:error, "bad_timing", "grace and max_runtime are text, such as 30m."}
      {:error, why} -> {:error, "bad_timing", why}
    end
  end

  def set_job_timing(conn, params), do: reply(conn, job_timing(params))

  defp texts?(params, keys), do: Enum.all?(keys, &is_binary(params[&1] || ""))

  def alert_settings(conn, _), do: reply(conn, Dokkit.Alerts.view())

  def save_alerts(params) do
    case Dokkit.Alerts.update(params) do
      {:ok, _, nil} -> Dokkit.Alerts.view()
      {:ok, _, note} -> Dokkit.Alerts.view() |> Map.put("note", note)
      {:error, why} -> {:error, "bad_settings", why}
    end
  end

  def set_alert_settings(conn, params), do: reply(conn, save_alerts(params))

  @test_cost 2_500

  @doc "Sends a test alert. Answers ok, or one fixed reason. Four tests at once for each caller, then one every 25 seconds."
  def try_alert(%{"channel" => channel}, who) when is_binary(channel) do
    with true <- Dokkit.Alerts.sends?(channel),
         :ok <- Dokkit.RateLimit.take({:alert_test, who}, @test_cost) do
      case Dokkit.Alerts.test(channel) do
        :ok -> %{ok: true}
        {:error, why} -> {:error, "send_failed", why}
      end
    else
      false ->
        {:error, "bad_channel", "channel is page, push, email, imessage, sms, digest or webhook."}

      {:wait, s} ->
        {:error, "slow_down", "Too many tests. Wait #{s} seconds."}
    end
  end

  def try_alert(_, _), do: {:error, "bad_channel", "Needs a channel."}

  def test_alert(conn, params), do: reply(conn, try_alert(params, conn.assigns.key.id))

  def suggestions(conn, _), do: list(conn, Read.suggestions())

  def suggestion(id, act), do: if(act.(id), do: %{ok: true}, else: not_found())

  def accept_suggestion(conn, %{"id" => id}),
    do: reply(conn, suggestion(id, &Dokkit.Alerts.accept_suggestion/1))

  def dismiss_suggestion(conn, %{"id" => id}),
    do: reply(conn, suggestion(id, &Dokkit.Alerts.dismiss_suggestion/1))

  @doc "Accepts or dismisses the command and pin that proposals showed for a task."
  def decide_task(%{"id" => id, "command" => command, "pin" => pin} = params, field)
      when is_binary(command) and is_binary(pin) do
    cond do
      !Enum.any?(Dokkit.Tasks.waiting(), &(&1.id == id)) ->
        not_found()

      Dokkit.Tasks.decide(id, command, pin, field, params["system"] in [true, "true"]) == :ok ->
        %{ok: true}

      true ->
        {:error, "changed",
         "The command or pin is not the one on offer now. Read proposals again."}
    end
  end

  def decide_task(_, _),
    do: {:error, "bad_task", "Needs command and pin, as proposals shows them."}

  def accept_task(conn, params), do: reply(conn, decide_task(params, :accepted))
  def dismiss_task(conn, params), do: reply(conn, decide_task(params, :dismissed))

  @doc "Asks an enrolled machine to fetch the newer program."
  def fetch_program(id, who) do
    case Read.machine(id) do
      %{kind: :enrolled} ->
        case Dokkit.Tasks.update(id, who) do
          nil -> {:error, "no_program", "This server holds no program for machines to fetch."}
          run -> %{run: run.id}
        end

      _ ->
        not_found()
    end
  end

  @doc "Approves a release for one machine, or for every machine that has an updater."
  def approve_update(version, id) do
    case Dokkit.Releases.approve(version, id) do
      {:ok, n} ->
        if id == :all,
          do: %{ok: true, version: version, machines: n},
          else: %{ok: true, version: version}

      error ->
        error
    end
  end

  # With a version it approves a release; without, it is the older fetch.
  def update_program(conn, %{"id" => id, "version" => version}),
    do: reply(conn, approve_update(version, id))

  def update_program(conn, %{"id" => id}),
    do: reply(conn, fetch_program(id, "token " <> (conn.assigns.key.label || "")))

  def releases(conn, _), do: list(conn, Dokkit.Releases.list())

  def update_all(conn, params), do: reply(conn, approve_update(params["version"], :all))

  def certificate(conn, _), do: json(conn, Dokkit.Certificate.view())

  def new_certificate(params) do
    case Dokkit.Certificate.put(params["cert"], params["key"]) do
      {:ok, view} -> view
      {:error, why} -> {:error, "bad_certificate", why}
    end
  end

  def drop_certificate do
    case Dokkit.Certificate.delete() do
      {:ok, view} -> view
      {:error, why} -> {:error, "bad_certificate", why}
    end
  end

  def put_certificate(conn, params), do: reply(conn, new_certificate(params))
  def delete_certificate(conn, _), do: reply(conn, drop_certificate())

  def archives(conn, _), do: list(conn, Read.archives())

  def restore_month(name) do
    case Dokkit.Logs.restore_named(name) do
      nil -> not_found()
      lines -> %{ok: true, lines: lines}
    end
  end

  def restore_archive(conn, %{"name" => name}), do: reply(conn, restore_month(name))

  defp one(conn, nil), do: missing(conn)
  defp one(conn, thing), do: json(conn, clean(conn, thing))

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
        known(conn, fn -> Issues.snooze(id, seconds) end)

      :error ->
        fail(conn, 422, "bad_time", "until must be a time in the future, in RFC 3339.")
    end
  end

  def snooze(conn, _), do: fail(conn, 422, "bad_time", "Needs until.")

  def unsnooze(conn, %{"id" => id}), do: known(conn, fn -> Issues.unsnooze(id) end)
  def acknowledge(conn, %{"id" => id}), do: known(conn, fn -> Issues.acknowledge(id) end)

  defp known(conn, act) do
    if act.() > 0, do: json(conn, %{ok: true}), else: missing(conn)
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
  defp list(conn, items), do: json(conn, %{items: clean(conn, items), next: nil})

  defp clean(conn, data),
    do: if("read-logs" in conn.assigns.key.scopes, do: data, else: Read.without_logs(data))

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
  # read-logs, keys, people, rules, alert settings, checks, restart, updating the program,
  # restoring logs, making a job and accepting a task need admin, and anything else
  # changes something.
  def needs(method, path) do
    case {method, Enum.at(path, 2), List.last(path)} do
      {_, area, _} when area in ["keys", "users", "update-all"] -> "admin"
      {"GET", "logs", _} -> "read-logs"
      {"GET", _, _} -> "read"
      {_, area, _} when area in ["rules", "alerts", "releases", "certificate"] -> "admin"
      {"POST", "tasks", last} when last in ["accept", "dismiss"] -> "admin"
      {"POST", area, area} when area in ["jobs", "apps"] -> "admin"
      {_, _, last} -> if last in ~w(checks restart update restore), do: "admin", else: "act"
    end
  end

  defp scope(conn, _) do
    scope = needs(conn.method, Enum.map(conn.path_info, &URI.decode/1))

    if scope in conn.assigns.key.scopes,
      do: conn,
      else: conn |> fail(403, "no_scope", "This token may not #{scope}.") |> halt()
  end
end
