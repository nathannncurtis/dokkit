defmodule DokkitWeb.ApiController do
  @moduledoc "The read and act calls, for a user token."
  use DokkitWeb, :controller
  require Logger
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

  def issues(conn, params), do: list(conn, Read.list(:issues, params))
  def machines(conn, params), do: list(conn, Read.list(:machines, params))
  def services(conn, params), do: list(conn, Read.list(:services, params))
  def jobs(conn, params), do: list(conn, Read.list(:jobs, params))
  def deploys(conn, params), do: list(conn, Read.list(:deploys, params))
  def errors(conn, params), do: list(conn, Read.list(:errors, params))
  def rules(conn, params), do: list(conn, Read.list(:rules, params))

  def keys(conn, params), do: list(conn, Read.list(:keys, params))
  def users(conn, params), do: list(conn, Read.list(:users, params))

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
    label = if is_binary(p["machine"]) and p["machine"] != "", do: String.trim(p["machine"])
    hours = Map.get(p, "hours", div(Keys.enrol_life(), 3600))

    if is_integer(hours) and hours in 1..Keys.enrol_most_hours() do
      minted(Keys.mint_enrol(label, hours * 3600))
    else
      {:error, "bad_hours", "hours is a whole number from 1 to #{Keys.enrol_most_hours()}."}
    end
  end

  def make_key(_, _),
    do: {:error, "bad_key", "kind is user with label and scopes, app with service, or enrol."}

  defp minted({text, key}), do: %{id: key.id, key: text}
  defp blank?(text), do: not is_binary(text) or String.trim(text) == ""

  def add_key(conn, p), do: reply(conn, make_key(p, conn.assigns.key))

  def add_script(conn, params), do: reply(conn, new_add_script(params))

  @doc "The one script that adds a Windows machine, holding a new enrolment token that lasts 24 hours."
  def new_add_script(params) do
    name = String.trim(to_string(params["name"] || ""))
    {token, key} = Keys.mint_enrol(if(name == "", do: "Add script", else: name), 24 * 3600)

    case Dokkit.AddScript.windows(
           if(name == "", do: "machine", else: name),
           token,
           key.expires_at
         ) do
      {:ok, file, text} ->
        %{command: Dokkit.AddScript.command(token), file: file, script: text, token_id: key.id}

      :no_release ->
        Keys.revoke(key.id)
        {:error, "no_release", "The server holds no complete release to install."}
    end
  end

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

  def drop_person(id, %{user_id: user_id}) do
    case Dokkit.Accounts.remove(id, %Dokkit.User{id: user_id}) do
      :ok -> %{ok: true}
      {:error, why} -> {:error, "bad_person", why}
    end
  end

  def add_user(conn, params), do: reply(conn, new_person(params))
  def remove_user(conn, %{"id" => id}), do: reply(conn, drop_person(id, conn.assigns.key))

  def versions(conn, _),
    do:
      json(conn, %{items: Read.versions(), apps: Read.apps(), program: Read.program(), next: nil})

  def proposals(conn, params), do: list(conn, Read.list(:proposals, params))
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
    with nil <- mixed_none(params, ~w(down degraded)),
         %{} = service <- Dokkit.Estate.service(id) do
      Read.routing(Dokkit.Estate.set_routing(service, params))
    else
      nil -> not_found()
      why -> {:error, "bad_routing", why}
    end
  end

  def routing(conn, params), do: reply(conn, set_routing(params))

  def set_machine_routing(%{"id" => id} = params) do
    with nil <- mixed_none(params, ["down"]),
         %{} = machine <- Dokkit.Estate.machine(id) do
      Read.silent(Dokkit.Estate.set_silent(machine, params))
    else
      nil -> not_found()
      why -> {:error, "bad_routing", why}
    end
  end

  def machine_routing(conn, params), do: reply(conn, set_machine_routing(params))

  defp mixed_none(params, keys) do
    Enum.find_value(keys, fn k ->
      channels = Dokkit.Alerts.split(params[k])

      if "none" in channels and length(channels) > 1,
        do: "#{k}: none cannot be combined with other channels."
    end)
  end

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

  def accept(conn, params), do: reply(conn, found(params, &Dokkit.Found.watch/1))
  def dismiss(conn, params), do: reply(conn, found(params, &Dokkit.Found.dismiss/1))

  @doc "Acts on one proposal (id), some (ids) or every one waiting and shown (all true; with system true, the operating system's own too)."
  def found(%{"id" => id}, act), do: found(%{"ids" => [id], "single" => true}, act)

  def found(%{"ids" => ids} = params, act) when is_list(ids) do
    waiting = MapSet.new(Dokkit.Found.list(system: true), & &1.id)
    known = Enum.filter(Enum.uniq(ids), &(&1 in waiting))

    if known == [] and !params["all"] do
      not_found()
    else
      act.(known)
      if params["single"], do: %{ok: true}, else: %{ok: true, done: known}
    end
  end

  def found(%{"all" => true} = params, act) do
    all = Dokkit.Found.list(system: params["system"] in [true, "true"])
    found(%{"ids" => Enum.map(all, & &1.id), "all" => true}, act)
  end

  def found(_, _), do: {:error, "bad_proposals", "Needs an id, ids, or all true."}

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

  def new_dependency(params) do
    with true <- texts?(params, ~w(name machine)),
         {:ok, id} <- Dokkit.Estate.add_dependency(params) do
      Read.service(id)
    else
      false -> {:error, "bad_dependency", "name and machine are text."}
      {:error, why} -> {:error, "bad_dependency", why}
    end
  end

  def add_dependency(conn, params), do: reply(conn, new_dependency(params))

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

  def phones(conn, _),
    do: json(conn, %{items: Enum.map(Dokkit.Phones.list(), &Dokkit.Phones.view/1), next: nil})

  def new_phone(params) do
    case Dokkit.Phones.add(params["name"]) do
      {:ok, phone, code} -> phone |> Dokkit.Phones.view() |> Map.put(:code, code)
      {:error, why} -> {:error, "bad_phone", why}
    end
  end

  def drop_phone(id), do: if(Dokkit.Phones.remove(id) == :ok, do: %{ok: true}, else: not_found())

  def add_phone(conn, params), do: reply(conn, new_phone(params))
  def remove_phone(conn, %{"id" => id}), do: reply(conn, drop_phone(id))

  def get_relay(conn, _), do: json(conn, Dokkit.Phones.relay_view())

  @doc "Saves the relay, makes one upload, and answers the relay as it is with the words for what the upload did."
  def save_relay(params), do: relay_saved(Dokkit.Phones.save_relay(params))

  def shared_relay, do: relay_saved(Dokkit.Phones.use_shared_relay())

  defp relay_saved({:ok, _}) do
    result = Dokkit.Phones.upload(force: true)

    Dokkit.Phones.relay_view()
    |> Map.merge(%{uploaded: result == :ok, result: Dokkit.Phones.words(result)})
  end

  defp relay_saved({:error, why}), do: {:error, "bad_relay", why}

  def put_relay(conn, params), do: reply(conn, save_relay(params))

  def post_shared_relay(conn, _), do: reply(conn, shared_relay())

  def shared_heartbeat do
    case Dokkit.SharedBeat.use() do
      {:ok, s} -> %{heartbeat_url: s["url"], kind: s["kind"]}
      {:error, why} -> {:error, "bad_heartbeat", why}
    end
  end

  def use_shared_heartbeat(conn, _), do: reply(conn, shared_heartbeat())

  def stop_shared_heartbeat(conn, _) do
    Dokkit.SharedBeat.stop()
    reply(conn, %{heartbeat_url: nil})
  end

  def alert_settings(conn, _), do: reply(conn, Dokkit.Alerts.view())

  def save_alerts(params) do
    case Dokkit.Alerts.update(params) do
      {:ok, _, nil} -> Dokkit.Alerts.view()
      {:ok, _, note} -> Dokkit.Alerts.view() |> Map.put("note", note)
      {:error, why} -> {:error, "bad_settings", why}
    end
  end

  def set_alert_settings(conn, params), do: reply(conn, save_alerts(params))

  def alert_people(conn, _), do: list(conn, %{items: Dokkit.People.view(), next: nil})

  def save_person(%{"id" => id} = params) do
    case Dokkit.People.update(id, params) do
      {:ok, person} -> Dokkit.People.view(person)
      :not_found -> not_found()
      {:error, why} -> {:error, "bad_person", why}
    end
  end

  def set_alert_person(conn, params), do: reply(conn, save_person(params))

  def alert_who(conn, _), do: list(conn, %{items: Dokkit.People.who_list(), next: nil})

  def save_who(params) do
    id =
      if params["scope"] == "check" and is_binary(params["service"]),
        do: Dokkit.People.check_id(params["service"], params["name"]) || "",
        else: params["id"]

    case Dokkit.People.set_who(params["scope"], id, params["to"]) do
      {:ok, entry} -> entry
      {:error, why} -> {:error, "bad_who", why}
    end
  end

  def set_alert_who(conn, params), do: reply(conn, save_who(params))

  @test_cost 2_500
  @open_test_cost 5_000

  @doc "Sends a test alert. Answers ok, or one fixed reason. Four tests at once for each caller, then one every 25 seconds. A test that stays open for two minutes costs twice as much: two at once, then one every 50 seconds."
  def try_alert(%{"channel" => channel} = params, who) when is_binary(channel) do
    person = params["person"] && Dokkit.People.get(params["person"])
    bad_person = params["person"] != nil and person == nil

    with true <- Dokkit.Alerts.sends?(channel),
         false <- bad_person,
         open? = Dokkit.Alerts.keeps_open?(channel),
         :ok <-
           Dokkit.RateLimit.take(
             {:alert_test, who},
             if(open?, do: @open_test_cost, else: @test_cost)
           ) do
      case Dokkit.Alerts.test(channel, person) do
        :ok when open? -> %{ok: true, resolves_in: Dokkit.Alerts.test_stays()}
        :ok -> %{ok: true}
        {:error, why} -> {:error, "send_failed", why}
      end
    else
      true ->
        {:error, "bad_person", "person is the id of a person on this server."}

      false ->
        {:error, "bad_channel", "channel is page, push, email, imessage, sms, digest or webhook."}

      {:wait, s} ->
        {:error, "slow_down", "Too many tests. Wait #{s} seconds."}
    end
  end

  def try_alert(_, _), do: {:error, "bad_channel", "Needs a channel."}

  def test_alert(conn, params), do: reply(conn, try_alert(params, conn.assigns.key.id))

  def suggestions(conn, _), do: json(conn, %{items: Read.suggestions(), next: nil})

  def suggestion(id, act), do: if(act.(id), do: %{ok: true}, else: not_found())

  def accept_suggestion(conn, %{"id" => id}),
    do: reply(conn, suggestion(id, &Dokkit.Alerts.accept_suggestion/1))

  def dismiss_suggestion(conn, %{"id" => id}),
    do: reply(conn, suggestion(id, &Dokkit.Alerts.dismiss_suggestion/1))

  @doc "Asks an enrolled machine to fetch the newer program."
  def fetch_program(id, who) do
    case Read.machine(id) do
      %{kind: :enrolled} ->
        case Dokkit.Work.update(id, who) do
          nil -> {:error, "no_program", "This server holds no program for machines to fetch."}
          run -> %{run: run.id}
        end

      _ ->
        not_found()
    end
  end

  @doc "Asks an enrolled machine to look itself over again and send what it finds."
  def look_again(id, who) do
    case Read.machine(id) do
      %{kind: :enrolled} -> %{run: Dokkit.Work.scan(id, who).id}
      _ -> not_found()
    end
  end

  def scan_machine(conn, %{"id" => id}),
    do: reply(conn, look_again(id, "token " <> (conn.assigns.key.label || "")))

  @doc "Starts planned downtime for an enrolled machine, or ends it with `for` of 0."
  def plan_downtime(id, params, who) do
    case Dokkit.Quiet.start(id, params, who) do
      {:ok, _} -> Read.machine(id) |> Map.take([:id, :name, :planned_downtime])
      error -> error
    end
  end

  def end_downtime(id, who) do
    case Dokkit.Quiet.stop(id, who) do
      {:ok, _} -> Read.machine(id) |> Map.take([:id, :name, :planned_downtime])
      error -> error
    end
  end

  @doc "A machine's scheduled planned downtime."
  def downtime_schedules(id) do
    if Dokkit.Quiet.machine_exists?(id),
      do: %{items: Dokkit.QuietSchedules.list(id), next: nil},
      else: not_found()
  end

  def schedule_downtime(id, params, who) do
    case Dokkit.QuietSchedules.add(id, params, who) do
      {:ok, schedule} ->
        Enum.find(Dokkit.QuietSchedules.list(id), &(&1.id == schedule.id))

      error ->
        error
    end
  end

  def unschedule_downtime(id, schedule) do
    case Dokkit.QuietSchedules.remove(id, schedule) do
      {:ok, _} -> %{ok: true}
      error -> error
    end
  end

  def quiet_schedules(conn, %{"id" => id}), do: reply(conn, downtime_schedules(id))

  def add_quiet_schedule(conn, %{"id" => id} = params),
    do: reply(conn, schedule_downtime(id, params, "token " <> (conn.assigns.key.label || "")))

  def remove_quiet_schedule(conn, %{"id" => id, "schedule" => schedule}),
    do: reply(conn, unschedule_downtime(id, schedule))

  def quiet_machine(conn, %{"id" => id} = params),
    do: reply(conn, plan_downtime(id, params, "token " <> (conn.assigns.key.label || "")))

  def end_quiet_machine(conn, %{"id" => id}),
    do: reply(conn, end_downtime(id, "token " <> (conn.assigns.key.label || "")))

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

  def releases(conn, params), do: list(conn, Read.list(:releases, params))

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

  def certificate_settings, do: Dokkit.Acme.view()

  def save_certificate_settings(params) do
    case Dokkit.Acme.save(params) do
      {:ok, view} -> view
      {:error, why} -> {:error, "bad_settings", why}
    end
  end

  def renew_certificate do
    case Dokkit.Acme.renew() do
      {:ok, _} -> Dokkit.Certificate.view()
      {:error, why} -> {:error, "renewal_failed", why}
    end
  end

  def certificate_name, do: Dokkit.Names.view()

  def claim_name(params) do
    text = &if(is_binary(params[&1]), do: params[&1], else: "")

    case Dokkit.Names.claim(text.("code"), text.("address")) do
      {:ok, _} -> Dokkit.Names.view()
      {:error, why} -> {:error, "bad_claim", why}
    end
  end

  def get_certificate_name(conn, _), do: json(conn, certificate_name())
  def post_certificate_name(conn, params), do: reply(conn, claim_name(params))
  def get_certificate_settings(conn, _), do: json(conn, certificate_settings())
  def put_certificate_settings(conn, params), do: reply(conn, save_certificate_settings(params))
  def renew(conn, _), do: certificates(conn, renew_certificate())

  defp certificates(conn, {:error, code, message}), do: fail(conn, 422, code, message)
  defp certificates(conn, view), do: json(conn, view)

  def put_certificate(conn, params), do: certificates(conn, new_certificate(params))
  def delete_certificate(conn, _), do: certificates(conn, drop_certificate())

  def archives(conn, _), do: json(conn, %{items: Read.archives(), next: nil})

  def restore_month(name) do
    case Dokkit.Logs.restore_named(name) do
      nil -> not_found()
      lines -> %{ok: true, lines: lines}
    end
  end

  def restore_archive(conn, %{"name" => name}), do: reply(conn, restore_month(name))

  def save_log_retention(params) do
    case Dokkit.Logs.save_retention(params) do
      {:ok, _} -> Dokkit.Logs.retention_view()
      {:error, why} -> {:error, "bad_settings", why}
    end
  end

  def get_log_retention(conn, _), do: json(conn, Dokkit.Logs.retention_view())
  def put_log_retention(conn, params), do: reply(conn, save_log_retention(params))

  def move_logs(conn, params), do: reply(conn, move_service_logs(params))

  def move_service_logs(%{"id" => id} = p) do
    with %{} = from <- Dokkit.Estate.service(id),
         {:ok, to} <- target(p["to"], from),
         {:ok, filter} <- move_filter(p),
         {:ok, range} <- move_range(p),
         {:ok, text} <- delete_text(p, "bad_move"),
         {:ok, level} <- delete_level(p, "bad_move") do
      opts = filter ++ range ++ text ++ level
      dry = p["dry"] in [true, "true"]
      n = Dokkit.Logs.move(from.id, to.id, [dry: dry] ++ opts)

      if dry do
        %{would_move: n}
      else
        Logger.info("Moved #{n} log lines from service #{from.id} to #{to.id}: #{inspect(opts)}")
        %{moved: n}
      end
    else
      nil -> not_found()
      {:error, _, _} = error -> error
    end
  end

  def delete_logs(conn, params), do: reply(conn, delete_service_logs(params))

  def delete_service_logs(%{"id" => id} = p) do
    with %{} = service <- Dokkit.Estate.service(id),
         {:ok, filter} <- move_filter(p, "bad_delete"),
         {:ok, range} <- move_range(p),
         {:ok, text} <- delete_text(p),
         {:ok, level} <- delete_level(p),
         opts = filter ++ range ++ text ++ level,
         true <- opts != [] || {:error, "no_filter", "Give at least one filter."} do
      dry = p["dry"] in [true, "true"]
      n = Dokkit.Logs.delete(service.id, [dry: dry] ++ opts)

      if dry do
        %{would_delete: n}
      else
        Logger.info("Deleted #{n} log lines of service #{service.id}: #{inspect(opts)}")
        %{deleted: n}
      end
    else
      nil -> not_found()
      {:error, _, _} = error -> error
    end
  end

  defp delete_text(p, code \\ "bad_delete")

  defp delete_text(%{"q" => q}, _) when is_binary(q),
    do: {:ok, if(String.trim(q) == "", do: [], else: [q: String.trim(q)])}

  defp delete_text(p, _) when not is_map_key(p, "q"), do: {:ok, []}
  defp delete_text(_, code), do: {:error, code, "q is a text."}

  defp delete_level(p, code \\ "bad_delete")

  defp delete_level(%{"level" => level}, code) do
    if level in Dokkit.Logs.levels(),
      do: {:ok, [level: level]},
      else: {:error, code, "level is one of #{Enum.join(Dokkit.Logs.levels(), ", ")}."}
  end

  defp delete_level(_, _), do: {:ok, []}

  defp target(to, from) do
    with true <- is_binary(to) || {:error, "bad_move", "to is a service id."},
         %{} = service <- Dokkit.Estate.service(to) || not_found(),
         true <- service.id != from.id || {:error, "bad_move", "to must be another service."} do
      {:ok, service}
    end
  end

  defp move_filter(p, code \\ "bad_move")

  defp move_filter(%{"field" => field, "values" => values}, code)
       when is_binary(field) and is_list(values) do
    if field =~ ~r/\A[A-Za-z0-9_]+\z/ and length(values) <= 200 and
         Enum.all?(values, &is_binary/1),
       do: {:ok, [field: field, values: values]},
       else: {:error, code, "field is letters, digits and _; values are at most 200 texts."}
  end

  defp move_filter(p, _) when not is_map_key(p, "field") and not is_map_key(p, "values"),
    do: {:ok, []}

  defp move_filter(_, code), do: {:error, code, "field and values go together."}

  defp move_range(p) do
    Enum.reduce_while([{"from", :from}, {"until", :until}], {:ok, []}, fn {key, opt},
                                                                          {:ok, acc} ->
      case p[key] do
        nil ->
          {:cont, {:ok, acc}}

        text ->
          case is_binary(text) && DateTime.from_iso8601(text) do
            {:ok, at, _} -> {:cont, {:ok, [{opt, at} | acc]}}
            _ -> {:halt, {:error, "bad_time", "#{key} must be a time, in RFC 3339."}}
          end
      end
    end)
  end

  defp one(conn, nil), do: missing(conn)
  defp one(conn, {:error, _, _} = error), do: reply(conn, error)
  defp one(conn, thing), do: json(conn, clean(conn, thing))

  def error(conn, %{"id" => id} = params), do: one(conn, Read.error(id, params))

  def service(conn, %{"id" => id}), do: one(conn, Read.service(id))

  def series(conn, %{"id" => id} = params), do: one(conn, Read.series(id, params))

  def machine_series(conn, %{"id" => id} = params),
    do: one(conn, Read.machine_series(id, params))

  def processes(conn, %{"id" => id} = params), do: one(conn, Read.processes(id, params))

  def process_history(conn, %{"id" => id} = params),
    do: one(conn, Read.process_history(id, params))

  def runs(conn, %{"id" => id} = params), do: list(conn, Read.list({:runs, id}, params))
  def logs(conn, params), do: list(conn, Read.list(:logs, params))

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
  defp list(conn, {:error, _, _} = error), do: reply(conn, error)

  defp list(conn, %{items: items, next: next} = page),
    do: json(conn, Map.merge(%{items: clean(conn, items), next: next}, Map.take(page, [:hidden])))

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
  # restoring logs, and making a job need admin, and anything else
  # changes something.
  def needs(method, path) do
    case {method, Enum.at(path, 2), List.last(path)} do
      {_, area, _} when area in ["keys", "users", "update-all", "phones", "add-script"] ->
        "admin"

      {"GET", "certificate", last} when last in ["settings", "name"] ->
        "admin"

      {_, "logs", "retention"} ->
        "admin"

      {"GET", "logs", _} ->
        "read-logs"

      {"GET", _, _} ->
        "read"

      {_, area, _} when area in ["rules", "alerts", "releases", "certificate"] ->
        "admin"

      {"POST", area, area} when area in ["jobs", "apps", "dependencies"] ->
        "admin"

      {_, _, last} ->
        if last in ~w(checks restart update restore move delete), do: "admin", else: "act"
    end
  end

  defp scope(conn, _) do
    scope = needs(conn.method, Enum.map(conn.path_info, &URI.decode/1))

    if scope in conn.assigns.key.scopes,
      do: conn,
      else: conn |> fail(403, "no_scope", "This token may not #{scope}.") |> halt()
  end
end
