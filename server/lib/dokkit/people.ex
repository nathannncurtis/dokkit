defmodule Dokkit.Person do
  use Ecto.Schema
  @primary_key {:user_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "people" do
    field :email, :string
    field :phone, :string
    field :imessage, :string
    field :ntfy_url, :string
    field :pushover_user, :string
    field :pagerduty_key, :string
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Dokkit.AlertWho do
  use Ecto.Schema
  @primary_key false

  schema "alert_who" do
    field :scope, :string, primary_key: true
    field :scope_id, :string, primary_key: true, default: ""
    field :people, {:array, :string}
  end
end

defmodule Dokkit.AlertTarget do
  use Ecto.Schema
  @primary_key false
  @foreign_key_type :binary_id

  schema "alert_targets" do
    field :alert_id, :binary_id
    field :person_id, :binary_id
    field :opened, :boolean, default: false
    field :closed, :boolean, default: false
  end
end

defmodule Dokkit.People do
  @moduledoc """
  The people an alert can be told to. A person is a user of the server with destinations of
  their own. Routing names people at four levels; "everyone" is the server-wide destinations
  on the Alerts page, as before.
  """
  import Ecto.Query
  alias Dokkit.{AlertTarget, AlertWho, Check, Person, Repo, Service, User}

  @fields ~w(email phone imessage ntfy_url pushover_user pagerduty_key)
  @hidden ~w(ntfy_url pushover_user pagerduty_key)
  @scopes ~w(default rule service check)

  def fields, do: @fields
  def hidden, do: @hidden
  def scopes, do: @scopes

  def list do
    Repo.all(
      from u in User,
        left_join: p in Person,
        on: p.user_id == u.id,
        order_by: u.name,
        select: {u, p}
    )
    |> Enum.map(&person/1)
  end

  defp person({u, p}) do
    Map.new(@fields, fn f -> {String.to_atom(f), p && Map.get(p, String.to_atom(f))} end)
    |> Map.merge(%{id: u.id, name: u.name, role: u.role})
  end

  def get(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %User{} = u <- Repo.get(User, id) do
      person({u, Repo.get(Person, id)})
    else
      _ -> nil
    end
  end

  @doc "A person as the API shows them: addresses that are secrets are only set or not set."
  def view(p) do
    marks =
      Map.new(@hidden, fn f ->
        {String.to_atom(f), if(p[String.to_atom(f)] in [nil, ""], do: "not set", else: "set")}
      end)

    Map.merge(p, marks)
  end

  def view, do: Enum.map(list(), &view/1)

  @doc "Saves the destinations given; one not given stays, an empty one clears it. `{:ok, person}`, `{:error, text}` or `:not_found`."
  def update(id, params) do
    given = Map.take(params, @fields)

    cond do
      get(id) == nil ->
        :not_found

      Enum.any?(given, fn {_, v} -> not is_binary(v) end) ->
        {:error, "Every destination is text."}

      why = Dokkit.Alerts.contact_error(given) ->
        {:error, why}

      true ->
        {:ok, id} = Ecto.UUID.cast(id)
        old = Repo.get(Person, id) || %Person{user_id: id}

        change =
          Map.new(given, fn {k, v} ->
            {String.to_atom(k), if(String.trim(v) == "", do: nil, else: String.trim(v))}
          end)

        Repo.insert_or_update!(Ecto.Changeset.change(old, change))
        {:ok, get(id)}
    end
  end

  @doc "Every choice of who is told, as `%{scope:, id:, to:}`."
  def who_list,
    do:
      for(
        w <- Repo.all(from w in AlertWho, order_by: [w.scope, w.scope_id]),
        do: %{scope: w.scope, id: w.scope_id, to: w.people}
      )

  defp rows, do: Map.new(Repo.all(AlertWho), &{{&1.scope, &1.scope_id}, &1.people})

  @doc "Who is named at one level, or nil when nothing is."
  def who(scope, id \\ ""), do: rows()[{scope, id}]

  @doc """
  Names who is told at one level: a list of person ids, `["everyone"]`, or `[]` to name
  nobody there so the level above decides.
  """
  def set_who(scope, id, to) do
    id = id || ""

    cond do
      scope not in @scopes ->
        {:error, "scope is one of #{Enum.join(@scopes, ", ")}."}

      not is_list(to) or not Enum.all?(to, &is_binary/1) ->
        {:error, "to is a list of person ids, or [\"everyone\"]."}

      "everyone" in to and length(to) > 1 ->
        {:error, "everyone stands alone."}

      bad = Enum.find(to -- ["everyone"], &(not known_person?(&1))) ->
        {:error, "#{bad} is not a person on this server."}

      not known_scope?(scope, id) ->
        {:error, "No such #{scope}."}

      true ->
        key = from(w in AlertWho, where: w.scope == ^scope and w.scope_id == ^scope_id(scope, id))

        if to == [] do
          Repo.delete_all(key)
        else
          Repo.insert!(
            %AlertWho{scope: scope, scope_id: scope_id(scope, id), people: Enum.uniq(to)},
            on_conflict: {:replace, [:people]},
            conflict_target: [:scope, :scope_id]
          )
        end

        {:ok, %{scope: scope, id: scope_id(scope, id), to: Enum.uniq(to)}}
    end
  end

  @doc "The id of a service's check by its name, or nil."
  def check_id(service_id, name) do
    with {:ok, sid} <- Ecto.UUID.cast(service_id),
         true <- is_binary(name),
         %Check{id: id} <- Repo.get_by(Check, service_id: sid, name: name) do
      id
    else
      _ -> nil
    end
  end

  defp scope_id("default", _), do: ""
  defp scope_id(_, id), do: id

  defp known_person?(id), do: match?({:ok, _}, Ecto.UUID.cast(id)) and get(id) != nil

  defp known_scope?("default", _), do: true
  defp known_scope?("rule", id), do: Enum.any?(Dokkit.Alerts.rules(), &(&1["id"] == id))

  defp known_scope?(scope, id) do
    schema = if scope == "service", do: Service, else: Check
    match?({:ok, _}, Ecto.UUID.cast(id)) and Repo.get(schema, id) != nil
  end

  @doc "A removed rule takes its choice of people with it."
  def forget(scope, id),
    do: Repo.delete_all(from w in AlertWho, where: w.scope == ^scope and w.scope_id == ^id)

  @doc """
  Who an alert goes to: `:everyone`, or the ids of the people named. The most specific level
  that names someone decides: the check, then the service, then the rule, then the default.
  People who no longer exist are dropped; if none is left it goes to everyone.
  """
  def audience(opts, rows \\ rows()) do
    levels = [{"check", opts[:check]}, {"service", opts[:service]}, {"rule", opts[:rule]}]

    Enum.find_value(levels ++ [{"default", ""}], :everyone, fn {scope, id} ->
      with true <- id != nil, ids when is_list(ids) <- rows[{scope, id}] do
        decided(ids)
      else
        _ -> nil
      end
    end)
  end

  def audience_rows, do: rows()

  defp decided(["everyone"]), do: :everyone

  defp decided(ids) do
    case Repo.all(from u in User, where: u.id in ^ids, select: u.id) do
      [] -> :everyone
      live -> live
    end
  end

  @doc "Records the people an alert goes to."
  def target(alert_id, :everyone), do: alert_id

  def target(alert_id, ids) do
    Repo.insert_all(AlertTarget, for(id <- ids, do: %{alert_id: alert_id, person_id: id}),
      on_conflict: :nothing
    )

    alert_id
  end

  def targets(alert_id) do
    Repo.all(
      from t in AlertTarget,
        join: u in User,
        on: u.id == t.person_id,
        left_join: p in Person,
        on: p.user_id == u.id,
        where: t.alert_id == ^alert_id,
        order_by: u.name,
        select: {t, u, p}
    )
    |> Enum.map(fn {t, u, p} -> %{person: person({u, p}), opened: t.opened, closed: t.closed} end)
  end

  def mark(alert_id, person_id, field) when field in [:opened, :closed] do
    Repo.update_all(
      from(t in AlertTarget, where: t.alert_id == ^alert_id and t.person_id == ^person_id),
      set: [{field, true}]
    )
  end

  @doc "The person ids each issue's alert went to. Issues told to everyone are not in it."
  def told(issue_ids) do
    Repo.all(
      from t in AlertTarget,
        join: a in Dokkit.Alert,
        on: a.id == t.alert_id,
        where: a.issue_id in ^issue_ids,
        select: {a.issue_id, t.person_id}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc "The configuration with one person's destination in place of the server-wide one for that channel."
  def overlay(config, p, channel) do
    case {channel, config["push_with"]} do
      {"page", _} -> Map.put(config, "pagerduty_key", p.pagerduty_key || "")
      {"push", "pagerduty"} -> Map.put(config, "pagerduty_key", p.pagerduty_key || "")
      {"push", "pushover"} -> Map.put(config, "pushover_user", p.pushover_user || "")
      {"push", _} -> ntfy(config, p)
      {c, _} when c in ["email", "digest"] -> Map.put(config, "email_to", p.email || "")
      {"sms", _} -> Map.put(config, "sms_to", p.phone || "")
      {"imessage", _} -> Map.put(config, "imessage_to", p.imessage || "")
      _ -> config
    end
  end

  # The server's access token goes only to the server's own host.
  defp ntfy(config, p) do
    url = p.ntfy_url || ""
    same = host(url) != "" and host(url) == host(config["ntfy_url"])

    config
    |> Map.put("ntfy_url", url)
    |> Map.put("ntfy_token", if(same, do: config["ntfy_token"], else: ""))
  end

  defp host(url), do: (URI.parse(String.trim(url || "")).host || "") |> String.downcase()
end
