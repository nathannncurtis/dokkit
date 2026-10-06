defmodule Dokkit.Issues do
  @moduledoc "Turns check results into issues. The rules are in spec/alerts.md."
  import Ecto.Query
  alias Dokkit.{Check, Issue, Repo, Service}

  @same_issue_seconds 30 * 60
  @rank %{ok: 0, unknown: 1, degraded: 2, down: 3}

  def record(%Check{} = check, state, opts \\ []) when state in [:ok, :degraded, :down] do
    # A service nobody is watching keeps no state and opens nothing.
    if Repo.exists?(from s in Service, where: s.id == ^check.service_id and not s.watched),
      do: check,
      else: recorded(check, state, opts)
  end

  defp recorded(check, state, opts) do
    at = opts[:at] || DateTime.utc_now()

    {fails, passes} =
      if state == :ok, do: {0, check.passes + 1}, else: {check.fails + 1, 0}

    confirmed =
      cond do
        state != :ok and fails >= check.fail_after -> state
        state == :ok and (check.state == :unknown or passes >= check.fail_after) -> :ok
        true -> check.state
      end

    check =
      Repo.update!(
        Ecto.Changeset.change(check,
          fails: fails,
          passes: passes,
          state: confirmed,
          note: opts[:note],
          value: opts[:value],
          checked_at: at
        )
      )

    service = Repo.get!(Service, check.service_id)

    case {confirmed, open_for(check)} do
      {:ok, %Issue{} = issue} ->
        Repo.update!(Ecto.Changeset.change(issue, closed_at: at))
        Dokkit.Alerts.closing(issue)

      {:ok, nil} ->
        nil

      {bad, %Issue{state: bad}} ->
        nil

      {bad, %Issue{} = issue} ->
        Repo.update!(Ecto.Changeset.change(issue, state: bad))

      {:unknown, nil} ->
        nil

      {bad, nil} ->
        open(check, service, bad, at, opts[:title])
    end

    refresh(service)
    check
  end

  @doc "Open issues that are not snoozed: what needs someone."
  def open_list(now \\ DateTime.utc_now()) do
    Repo.all(from i in listed(), where: is_nil(i.snoozed_until) or i.snoozed_until <= ^now)
  end

  def snoozed_list(now \\ DateTime.utc_now()) do
    Repo.all(from i in listed(), where: i.snoozed_until > ^now)
  end

  defp listed do
    from i in Issue,
      where: is_nil(i.closed_at),
      order_by: [desc: i.since],
      preload: [:machine, :service, :check, :alert]
  end

  def snooze(ids, seconds) when is_integer(seconds) and seconds > 0,
    do: set(ids, snoozed_until: DateTime.add(DateTime.utc_now(), seconds))

  def unsnooze(ids), do: set(ids, snoozed_until: nil)
  def acknowledge(ids), do: set(ids, acknowledged_at: DateTime.utc_now())

  @doc "Adds a note to an issue, open or closed. nil when there is no such issue."
  def note(id, text, by) do
    with {:ok, id} <- Ecto.UUID.cast(id), %Issue{} = issue <- Repo.get(Issue, id) do
      note = %{"at" => DateTime.utc_now(), "by" => by, "text" => String.slice(text, 0, 2000)}
      Repo.update!(Ecto.Changeset.change(issue, notes: issue.notes ++ [note]))
      changed(false)
    else
      _ -> nil
    end
  end

  defp set(ids, change) do
    ids = for id <- List.wrap(ids), match?({:ok, _}, Ecto.UUID.cast(id)), do: id
    Repo.update_all(from(i in Issue, where: i.id in ^ids and is_nil(i.closed_at)), set: change)
    changed(false)
  end

  def open_count, do: length(open_list())

  def subscribe, do: Phoenix.PubSub.subscribe(Dokkit.PubSub, "issues")
  @doc "Call after the change is committed: pages reload, and alerts waiting to go are sent."
  def changed(send \\ true) do
    if send, do: Dokkit.Alerts.flush()
    Phoenix.PubSub.broadcast(Dokkit.PubSub, "issues", :issues_changed)
  end

  @silent_seconds 180

  @doc "Opens an issue for each enrolled machine that has gone quiet, and closes it when the machine is back."
  def machines_sweep(now) do
    quiet = DateTime.add(now, -@silent_seconds)

    down =
      from i in Issue, where: i.kind == "machine" and is_nil(i.closed_at), select: i.machine_id

    gone =
      Repo.all(
        from m in Dokkit.Machine,
          where: m.kind == :enrolled and m.last_seen_at < ^quiet and m.id not in subquery(down)
      )

    for m <- gone do
      issue =
        Repo.insert!(%Issue{
          machine_id: m.id,
          kind: "machine",
          state: :down,
          title: "#{m.name} stopped reporting",
          since: m.last_seen_at
        })

      Dokkit.Alerts.plan(issue, nil)
    end

    back =
      Repo.all(
        from i in Issue,
          join: m in assoc(i, :machine),
          where: i.kind == "machine" and is_nil(i.closed_at) and m.last_seen_at >= ^quiet
      )

    for issue <- back do
      Repo.update!(Ecto.Changeset.change(issue, closed_at: now))
      Dokkit.Alerts.closing(issue)
    end

    length(gone) + length(back)
  end

  def machine_down?(machine_id) do
    Repo.exists?(
      from i in Issue,
        where: i.machine_id == ^machine_id and i.kind == "machine" and is_nil(i.closed_at)
    )
  end

  def machines do
    down =
      Repo.all(
        from i in Issue, where: i.kind == "machine" and is_nil(i.closed_at), select: i.machine_id
      )

    Repo.all(
      from m in Dokkit.Machine,
        left_join: s in assoc(m, :services),
        group_by: m.id,
        order_by: m.name,
        # A PC that only an app reported from has nothing of its own to list.
        having: m.kind != :seen or count(s.id) > 0,
        select: %{
          id: m.id,
          name: m.name,
          kind: m.kind,
          os: m.os,
          last_seen_at: m.last_seen_at,
          services: count(s.id),
          bad: count(s.id) |> filter(s.state in [:degraded, :down])
        }
    )
    |> Enum.map(fn m ->
      gone = m.id in down
      Map.merge(m, %{down: gone, state: if(gone or m.bad > 0, do: "warn", else: "")})
    end)
  end

  defp open_for(check),
    do: Repo.one(from i in Issue, where: i.check_id == ^check.id and is_nil(i.closed_at))

  defp open(check, service, state, at, title) do
    recent =
      Repo.one(
        from i in Issue,
          where:
            i.check_id == ^check.id and i.closed_at > ^DateTime.add(at, -@same_issue_seconds),
          order_by: [desc: i.closed_at],
          limit: 1
      )

    if recent do
      Dokkit.Alerts.reopened(recent)

      Repo.update!(
        Ecto.Changeset.change(recent, closed_at: nil, state: state, count: recent.count + 1)
      )
    else
      issue =
        Repo.insert!(%Issue{
          machine_id: service.machine_id,
          service_id: service.id,
          check_id: check.id,
          kind: to_string(check.type),
          state: state,
          title: title || "#{service.name}: #{check.name} is #{state}",
          since: at
        })

      Dokkit.Alerts.plan(issue, service)
      issue
    end
  end

  # A service is as bad as its worst check, and says what that check said.
  defp refresh(service) do
    checks =
      Repo.all(from c in Check, where: c.service_id == ^service.id, select: {c.state, c.note})

    {state, note} =
      Enum.max_by(checks, fn {state, _} -> @rank[state] end, fn -> {:unknown, nil} end)

    note = if state in [:degraded, :down], do: note
    Repo.update!(Ecto.Changeset.change(service, state: state, note: note))
  end
end
