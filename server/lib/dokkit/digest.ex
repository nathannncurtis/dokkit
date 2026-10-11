defmodule Dokkit.Digest do
  @moduledoc """
  One mail a day with what did not page. A day with nothing to say sends nothing. Each person
  named in the routing gets a mail of their own with what was theirs; the server-wide address
  gets the rest.
  """
  import Ecto.Query
  require Logger
  alias Dokkit.{Alert, Check, ErrorGroup, Issue, People, Repo, Setting}

  @doc "Sends today's digest once the set time has passed. Returns :sent, :nothing or :not_yet."
  def tick(now, config) do
    today = Date.to_iso8601(DateTime.to_date(now))
    state = (Repo.get(Setting, "digest") || %Setting{value: %{}}).value

    cond do
      state["sent"] == today -> :not_yet
      Calendar.strftime(now, "%H:%M") < (config["digest_at"] || "07:00") -> :not_yet
      mailboxes(config) == [] -> :not_yet
      true -> send(now, today, config, if(state["day"] == today, do: state["done"], else: []))
    end
  end

  defp mailboxes(config) do
    everyone =
      if config["email_to"] in [nil, ""],
        do: [],
        else: [{"everyone", :everyone, config["email_to"]}]

    people = for p <- People.list(), p.email not in [nil, ""], do: {p.id, p.id, p.email}
    everyone ++ people
  end

  defp send(now, today, config, done) do
    waiting =
      Repo.all(
        from a in Alert,
          where: a.channel == "digest" and a.status == :pending,
          select: {a.id, a.issue_id}
      )

    also = Enum.map(waiting, &elem(&1, 1))
    since = DateTime.add(now, -86_400)
    boxes = Enum.reject(mailboxes(config), fn {key, _, _} -> key in done end)

    results =
      for {key, who, to} <- boxes do
        case lines(since, also, who) do
          [] -> {key, :nothing}
          lines -> {key, Dokkit.Mail.send(to, "Dokkit: yesterday", lines, config)}
        end
      end

    sent = done ++ for({key, r} <- results, r in [:ok, :nothing], do: key)
    failed = Enum.find(results, fn {_, r} -> r not in [:ok, :nothing] end)

    if failed do
      if sent != [], do: remember(%{"day" => today, "done" => sent})
      Logger.warning("The daily digest was not sent: #{elem(elem(failed, 1), 1)}")
      elem(failed, 1)
    else
      remember(%{"sent" => today})
      ids = Enum.map(waiting, &elem(&1, 0))
      Repo.update_all(from(a in Alert, where: a.id in ^ids), set: [status: :sent])
      if Enum.any?(results, fn {_, r} -> r == :ok end), do: :sent, else: :nothing
    end
  end

  defp remember(value) do
    Repo.insert!(%Setting{key: "digest", value: value},
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )
  end

  @doc """
  What the digest says about the time since `since`, and about `also` issues, however old. `who`
  is `:everyone` for what the server-wide address gets, or a person's id for what is theirs.
  """
  def lines(since, also \\ [], who \\ :everyone) do
    paged = from a in Alert, where: a.channel == "page", select: a.issue_id
    rows = People.audience_rows()

    opened =
      Repo.all(
        from i in Issue,
          where: (i.since >= ^since or i.id in ^also) and i.id not in subquery(paged),
          order_by: i.since,
          preload: :machine
      )

    closed =
      Repo.all(
        from i in Issue,
          where:
            i.closed_at >= ^since and i.since < ^since and i.id not in ^also and
              i.id not in subquery(paged),
          order_by: i.closed_at,
          preload: :machine
      )

    told = People.told(Enum.map(opened ++ closed, & &1.id))
    issue? = &theirs?(told[&1.id] || :everyone, who)

    errors =
      Repo.all(
        from g in ErrorGroup,
          where: g.first_seen >= ^since,
          order_by: g.first_seen,
          preload: [service: :machine]
      )
      |> Enum.filter(&theirs?(People.audience([service: &1.service_id], rows), who))

    close =
      Repo.all(
        from c in Check,
          where: c.type == :threshold and c.state == :ok and not is_nil(c.value),
          preload: :service
      )

    close =
      for c <- close,
          limit = Dokkit.Numbers.limit(c),
          is_number(limit),
          c.value >= 0.9 * limit,
          theirs?(People.audience([check: c.id, service: c.service_id], rows), who),
          do: {c, limit}

    section(
      "Opened without paging",
      for(i <- opened, issue?.(i), do: "#{i.title} (#{i.machine.name})")
    ) ++
      section(
        "Closed without paging",
        for(i <- closed, issue?.(i), do: "#{i.title} (#{i.machine.name})")
      ) ++
      section(
        "New errors",
        for(
          g <- errors,
          do:
            "#{g.type} in #{g.service.name} on #{g.host || g.service.machine.name}, #{g.count} reports"
        )
      ) ++
      section(
        "Close to a limit",
        for(
          {c, limit} <- close,
          do: "#{c.service.name}: #{c.name} is at #{Float.round(c.value, 1)} of #{limit}"
        )
      )
  end

  defp theirs?(:everyone, who), do: who == :everyone
  defp theirs?(ids, who), do: who != :everyone and who in ids

  defp section(_, []), do: []
  defp section(title, rows), do: [title <> ":"] ++ rows ++ [""]
end
