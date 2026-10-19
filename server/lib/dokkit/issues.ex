defmodule Dokkit.Issues do
  @moduledoc "Turns check results into issues."
  import Ecto.Query
  alias Dokkit.{Check, Issue, Repo, Service}

  @same_issue_seconds 30 * 60
  @rank %{ok: 0, unknown: 1, degraded: 2, down: 3}

  @doc """
  Records a check result. Pass `soon: true` when a degraded result is a warning ahead of a
  failure: the issue lists under Soon and never pages. An expiry check is always soon.
  `at` is when the result happened; `now` is when the server got it and decides whether an
  alert is held for the night. Only tests pass `now`.
  """
  def record(%Check{} = check, state, opts \\ []) when state in [:ok, :degraded, :down] do
    service = Repo.get!(Service, check.service_id)

    cond do
      # A service nobody is watching keeps no state and opens nothing.
      not service.watched ->
        check

      # In planned downtime a bad result is only noted as seen, so it counts toward nothing.
      state != :ok and Dokkit.Quiet.quiet?(service.machine_id) ->
        Repo.update!(Ecto.Changeset.change(check, checked_at: opts[:at] || DateTime.utc_now()))

      true ->
        recorded(check, state, opts)
    end
  end

  defp recorded(check, state, opts) do
    now = opts[:now] || DateTime.utc_now()
    at = opts[:at] || now

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
    soon = soon?(check, confirmed, opts)

    case {confirmed, open_for(check)} do
      {:ok, %Issue{} = issue} ->
        close(issue, at)

      {:ok, nil} ->
        nil

      {bad, %Issue{soon: ^soon, state: bad} = issue} ->
        Repo.update!(Ecto.Changeset.change(issue, title: opts[:title] || issue.title))

      # A different state or soon is a different issue: a warning that becomes a failure alerts as a new failure.
      {bad, %Issue{} = issue} ->
        close(issue, at)
        open(check, service, bad, at, opts[:title], soon, now, issue)

      {:unknown, nil} ->
        nil

      {bad, nil} ->
        open(check, service, bad, at, opts[:title], soon, now)
    end

    refresh(service)
    check
  end

  @doc "Open issues that are not snoozed: what needs someone."
  def open_list(now \\ DateTime.utc_now()) do
    Repo.all(from i in listed(), where: is_nil(i.snoozed_until) or i.snoozed_until <= ^now)
  end

  @doc "Open issues that are not snoozed, split: `soon`, `other` (not production, not soon), and `needs_you`."
  def groups(now \\ DateTime.utc_now()) do
    {soon, rest} = Enum.split_with(open_list(now), & &1.soon)

    {other, needs_you} =
      Enum.split_with(rest, &(&1.service && &1.service.environment != "production"))

    %{needs_you: needs_you, soon: soon, other: other}
  end

  @doc "How many issues need someone, for each machine id: only what is under Needs you."
  def attention_by_machine, do: Enum.frequencies_by(groups().needs_you, & &1.machine_id)

  @doc "Production services that are fine, and how many machines they are on. A machine that stopped reporting has none."
  def fine do
    busy =
      from i in Issue,
        where: is_nil(i.closed_at) and not is_nil(i.service_id),
        select: i.service_id

    down =
      from i in Issue, where: i.kind == "machine" and is_nil(i.closed_at), select: i.machine_id

    quiet =
      from s in Service,
        where:
          s.watched and s.environment == "production" and s.state == :ok and
            s.id not in subquery(busy) and s.machine_id not in subquery(down)

    %{
      services: Repo.aggregate(quiet, :count),
      machines: Repo.one(from s in quiet, select: count(s.machine_id, :distinct))
    }
  end

  def snoozed_list(now \\ DateTime.utc_now()) do
    Repo.all(from i in listed(), where: i.snoozed_until > ^now)
  end

  defp listed do
    from i in Issue,
      where: is_nil(i.closed_at),
      order_by: [desc: i.since],
      preload: [:machine, :service, :check, :alerts]
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

    {count, _} =
      Repo.update_all(from(i in Issue, where: i.id in ^ids and is_nil(i.closed_at)), set: change)

    changed(false)
    count
  end

  def open_count do
    now = DateTime.utc_now()

    Repo.one(
      from i in Issue,
        left_join: s in assoc(i, :service),
        where: is_nil(i.closed_at) and not i.soon,
        where: is_nil(i.snoozed_until) or i.snoozed_until <= ^now,
        where: is_nil(s.id) or s.environment == "production",
        select: count(i.id)
    )
  end

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
    Dokkit.Quiet.tick(now)

    down =
      from i in Issue, where: i.kind == "machine" and is_nil(i.closed_at), select: i.machine_id

    planned =
      from w in Dokkit.QuietWindow,
        where: is_nil(w.ended_at) and w.until > ^now,
        select: w.machine_id

    gone =
      Repo.all(
        from m in Dokkit.Machine,
          where:
            m.kind == :enrolled and m.last_seen_at < ^quiet and m.id not in subquery(down) and
              m.id not in subquery(planned)
      )

    for m <- gone do
      issue =
        Repo.insert!(%Issue{
          machine_id: m.id,
          kind: "machine",
          state: :down,
          title: "#{m.name} stopped reporting",
          since: m.last_seen_at,
          notes: planned_note(m, now)
        })

      Dokkit.Alerts.plan(issue, nil, now)
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

    # What opened while the machine was down was held back; now it can be told.
    unalerted =
      Repo.all(
        from i in Issue,
          left_join: a in assoc(i, :alerts),
          where:
            i.machine_id in ^Enum.map(back, & &1.machine_id) and i.kind != "machine" and
              is_nil(i.closed_at) and is_nil(i.acknowledged_at) and is_nil(a.id) and
              (is_nil(i.snoozed_until) or i.snoozed_until <= ^now),
          preload: :service
      )

    went = Map.new(back, &{&1.machine_id, &1.since})

    for i <- unalerted,
        DateTime.compare(i.since, went[i.machine_id]) != :lt,
        do: Dokkit.Alerts.plan(i, i.service)

    length(gone) + length(back)
  end

  defp planned_note(m, now) do
    case Dokkit.Quiet.covering(m.id, m.last_seen_at) do
      nil ->
        []

      w ->
        end_text = Calendar.strftime(Dokkit.Quiet.over_at(w), "%H:%M")
        why = if w.reason, do: " (#{w.reason})", else: ""

        [
          %{
            "at" => now,
            "by" => "dokkit",
            "text" =>
              "Planned downtime ended at #{end_text} UTC#{why}. The machine has not reported since #{Calendar.strftime(m.last_seen_at, "%H:%M")} UTC."
          }
        ]
    end
  end

  def machine_down?(machine_id) do
    Repo.exists?(
      from i in Issue,
        where: i.machine_id == ^machine_id and i.kind == "machine" and is_nil(i.closed_at)
    )
  end

  def machines do
    now = DateTime.utc_now()

    # One query for every machine's open issues: down, under Needs you, and under Soon.
    counts =
      Repo.all(
        from i in Issue,
          left_join: s in assoc(i, :service),
          where: is_nil(i.closed_at),
          group_by: i.machine_id,
          select:
            {i.machine_id, count(i.id) |> filter(i.kind == "machine"),
             count(i.id)
             |> filter(
               (is_nil(i.snoozed_until) or i.snoozed_until <= ^now) and not i.soon and
                 (is_nil(s.id) or s.environment == "production")
             ),
             count(i.id)
             |> filter((is_nil(i.snoozed_until) or i.snoozed_until <= ^now) and i.soon)}
      )
      |> Map.new(fn {id, down, needs, soon} -> {id, {down > 0, needs, soon}} end)

    Repo.all(
      from m in Dokkit.Machine,
        left_join: s in assoc(m, :services),
        left_join: w in Dokkit.QuietWindow,
        on: w.machine_id == m.id and is_nil(w.ended_at) and w.until > ^now,
        group_by: [m.id, w.id],
        order_by: m.name,
        # A PC that only an app reported from has nothing of its own to list.
        having: m.kind != :seen or count(s.id, :distinct) > 0,
        select: %{
          planned: %{started_at: w.started_at, until: w.until, reason: w.reason, by: w.by},
          id: m.id,
          name: m.name,
          kind: m.kind,
          os: m.os,
          last_seen_at: m.last_seen_at,
          services: count(s.id, :distinct),
          bad: count(s.id, :distinct) |> filter(s.state in [:degraded, :down])
        }
    )
    |> Enum.map(fn m ->
      {gone, n, soon} = counts[m.id] || {false, 0, 0}

      Map.merge(m, %{
        planned: if(m.planned.until, do: struct(Dokkit.QuietWindow, m.planned)),
        down: gone,
        attention: n,
        soon: soon,
        state: if(gone or n > 0, do: "warn", else: "")
      })
    end)
  end

  defp close(issue, at) do
    Repo.update!(Ecto.Changeset.change(issue, closed_at: at))
    Dokkit.Alerts.closing(issue)
  end

  defp open_for(check),
    do: Repo.one(from i in Issue, where: i.check_id == ^check.id and is_nil(i.closed_at))

  defp soon?(check, state, opts),
    do: state == :degraded and (opts[:soon] == true or check.type == :expiry)

  defp open(check, service, state, at, title, soon, now, from \\ nil) do
    recent =
      Repo.one(
        from i in Issue,
          where:
            i.check_id == ^check.id and i.soon == ^soon and i.state == ^state and
              i.closed_at > ^DateTime.add(at, -@same_issue_seconds),
          order_by: [desc: i.closed_at],
          limit: 1
      )

    if recent do
      reopened =
        Repo.update!(
          Ecto.Changeset.change(recent,
            closed_at: nil,
            state: state,
            soon: soon,
            count: recent.count + 1
          )
        )

      Dokkit.Alerts.reopened(reopened, now)
      reopened
    else
      {:ok, issue} =
        Repo.transaction(fn -> successor(check, service, state, at, title, soon, now, from) end)

      issue
    end
  end

  # The issue a person follows keeps its number and notes when its state changes. A snooze and
  # "seen" go with it, except on the way to down: that always comes back and alerts.
  defp successor(check, service, state, at, title, soon, now, from) do
    heir = if from && state != :down, do: from
    snoozed = heir && heir.snoozed_until && DateTime.compare(heir.snoozed_until, now) == :gt

    issue =
      Repo.insert!(%Issue{
        machine_id: service.machine_id,
        service_id: service.id,
        check_id: check.id,
        kind: to_string(check.type),
        state: state,
        soon: soon,
        title: title || plain_title(service, check, state),
        since: at,
        number: from && renumber(from),
        processes: Dokkit.Processes.snapshot(check, service.machine_id, state, now),
        notes: (from && from.notes) || [],
        snoozed_until: if(snoozed, do: heir.snoozed_until),
        acknowledged_at: heir && heir.acknowledged_at
      })

    unless snoozed || (heir && heir.acknowledged_at),
      do: Dokkit.Alerts.plan(issue, service, now)

    issue
  end

  # The closed issue takes a fresh number so the successor can keep the one people saw.
  defp renumber(%Issue{id: id, number: number}) do
    Repo.update_all(
      from(i in Issue,
        where: i.id == ^id,
        update: [set: [number: fragment("nextval(pg_get_serial_sequence('issues', 'number'))")]]
      ),
      []
    )

    number
  end

  # A service with one check, or a check named like the service or `up`, is named alone.
  defp plain_title(service, check, state) do
    only? = Repo.aggregate(from(c in Check, where: c.service_id == ^service.id), :count) == 1

    if only? or String.downcase(check.name) in ["up", String.downcase(service.name), service.slug],
      do: "#{service.name} is #{state}",
      else: "#{service.name}: #{check.name} is #{state}"
  end

  # A service is as bad as its worst check, and says what that check said.
  def refresh(service) do
    checks =
      Repo.all(from c in Check, where: c.service_id == ^service.id, select: {c.state, c.note})

    {state, note} =
      Enum.max_by(checks, fn {state, _} -> @rank[state] end, fn -> {:unknown, nil} end)

    note = if state in [:degraded, :down], do: note
    Repo.update!(Ecto.Changeset.change(service, state: state, note: note))
  end
end
