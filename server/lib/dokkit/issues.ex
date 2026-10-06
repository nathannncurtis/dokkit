defmodule Dokkit.Issues do
  @moduledoc "Turns check results into issues. The rules are in spec/alerts.md."
  import Ecto.Query
  alias Dokkit.{Check, Issue, Repo, Service}

  @same_issue_seconds 30 * 60
  @rank %{ok: 0, unknown: 1, degraded: 2, down: 3}

  def record(%Check{} = check, state, opts \\ []) when state in [:ok, :degraded, :down] do
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

  def open_list do
    Repo.all(
      from i in Issue,
        where: is_nil(i.closed_at),
        order_by: [desc: i.since],
        preload: [:machine, :service, :check, :alert]
    )
  end

  def open_count, do: Repo.aggregate(from(i in Issue, where: is_nil(i.closed_at)), :count)

  def subscribe, do: Phoenix.PubSub.subscribe(Dokkit.PubSub, "issues")
  @doc "Call after the change is committed: pages reload, and alerts waiting to go are sent."
  def changed(send \\ true) do
    if send, do: Dokkit.Alerts.flush()
    Phoenix.PubSub.broadcast(Dokkit.PubSub, "issues", :issues_changed)
  end

  @doc "Each machine with how many of its services need a look."
  def machines do
    Repo.all(
      from m in Dokkit.Machine,
        left_join: s in assoc(m, :services),
        group_by: m.id,
        order_by: m.name,
        select: %{
          id: m.id,
          name: m.name,
          services: count(s.id),
          bad: count(s.id) |> filter(s.state in [:degraded, :down])
        }
    )
    |> Enum.map(&Map.put(&1, :state, if(&1.bad > 0, do: "warn", else: "")))
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
