defmodule Dokkit.Quiet do
  @moduledoc "Planned downtime: a window in which a machine going silent, and its checks failing, open nothing. The rules are in spec/alerts.md."
  import Ecto.Query
  alias Dokkit.{Check, Machine, QuietWindow, Repo}

  @most 4 * 3600
  @silent_seconds 90
  @units %{"s" => 1, "m" => 60, "h" => 3600}
  @reported ~w(http tcp process windows-service systemd custom)a

  def most, do: @most

  @doc "A duration such as 90s, 15m or 4h as seconds; 0 ends a window. Errors above the most."
  def parse(text) when is_binary(text) do
    case Regex.run(~r/^(\d+)([smh]?)$/, String.trim(text)) do
      [_, "0", _] ->
        {:ok, 0}

      [_, n, unit] ->
        seconds = String.to_integer(n) * @units[if(unit == "", do: "s", else: unit)]
        if seconds in 1..@most, do: {:ok, seconds}, else: :error

      _ ->
        :error
    end
  end

  def parse(_), do: :error

  @doc "Starts a window for a machine, replacing one that is running. `for` of 0 ends it."
  def start(machine_id, %{} = params, by) do
    with {:ok, seconds} <- parse(params["for"]),
         %Machine{kind: :enrolled} <- machine(machine_id) do
      if seconds == 0 do
        stop(machine_id, by)
      else
        now = DateTime.utc_now()
        reason = reason(params["reason"])
        ended(machine_id, now, "replaced by " <> by)

        window =
          Repo.insert!(%QuietWindow{
            machine_id: machine_id,
            started_at: now,
            until: DateTime.add(now, seconds),
            reason: reason,
            by: by
          })

        Dokkit.Issues.changed(false)
        {:ok, window}
      end
    else
      :error ->
        {:error, "bad_duration",
         "for is a duration up to #{div(@most, 3600)}h, such as 15m, or 0 to end it."}

      _ ->
        {:error, "not_found", "No such thing."}
    end
  end

  def stop(machine_id, by) do
    case machine(machine_id) do
      %Machine{kind: :enrolled} ->
        ended(machine_id, DateTime.utc_now(), by)
        Dokkit.Issues.changed(false)
        {:ok, nil}

      _ ->
        {:error, "not_found", "No such thing."}
    end
  end

  defp machine(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(Machine, id)
      _ -> nil
    end
  end

  defp reason(text) when is_binary(text) do
    case text |> String.trim() |> String.slice(0, 200) do
      "" -> nil
      text -> text
    end
  end

  defp reason(_), do: nil

  defp ended(machine_id, now, by) do
    Repo.update_all(running(machine_id, now), set: [ended_at: now, ended_by: by])
  end

  defp running(machine_id, now),
    do:
      from(w in QuietWindow,
        where: w.machine_id == ^machine_id and is_nil(w.ended_at) and w.until > ^now
      )

  @doc "Whether the machine is in a planned window now."
  def quiet?(nil, _), do: false
  def quiet?(machine_id, now), do: Repo.exists?(running(machine_id, now))

  def quiet?(machine_id), do: quiet?(machine_id, DateTime.utc_now())

  @doc "The windows running now."
  def active(now \\ DateTime.utc_now()) do
    Repo.all(
      from w in QuietWindow, where: is_nil(w.ended_at) and w.until > ^now, order_by: w.until
    )
  end

  @doc "What the API shows of a window."
  def view(nil), do: nil

  def view(%QuietWindow{} = w) do
    %{
      started_at: w.started_at,
      until: w.until,
      ended_at: w.ended_at,
      reason: w.reason,
      by: w.by,
      ended_by: w.ended_by
    }
  end

  @doc "A machine's windows, newest first."
  def history(machine_id, limit \\ 20) do
    Repo.all(
      from w in QuietWindow,
        where: w.machine_id == ^machine_id,
        order_by: [desc: w.started_at],
        limit: ^limit
    )
  end

  @doc "When a window actually stopped covering the machine: ended early, or its time."
  def over_at(%QuietWindow{ended_at: nil, until: until}), do: until
  def over_at(%QuietWindow{ended_at: at}), do: at

  @doc "For each machine with a window, when its latest one stopped covering it: jobs and beats are judged from then on."
  def overs do
    Repo.all(
      from w in QuietWindow,
        group_by: w.machine_id,
        select: {w.machine_id, type(max(coalesce(w.ended_at, w.until)), :utc_datetime_usec)}
    )
    |> Map.new()
  end

  @doc "The machine's window that ended after it last reported, if any: why it is silent."
  def covering(machine_id, last_seen_at) do
    Repo.one(
      from w in QuietWindow,
        where:
          w.machine_id == ^machine_id and
            coalesce(w.ended_at, w.until) >= ^(last_seen_at || ~U[1970-01-01 00:00:00Z]),
        order_by: [desc: w.started_at],
        limit: 1
    )
  end

  @doc """
  Once a minute. Notes that a machine in a window has gone silent. Ends a window early when the
  machine reported again after that and every reported check has reported since it went silent.
  """
  def tick(now) do
    quiet = DateTime.add(now, -@silent_seconds)

    Repo.update_all(
      from(w in QuietWindow,
        join: m in assoc(w, :machine),
        where: is_nil(w.ended_at) and w.until > ^now and is_nil(w.silent_at),
        where: m.last_seen_at < ^quiet,
        update: [set: [silent_at: ^now]]
      ),
      []
    )

    waiting =
      Repo.all(
        from w in QuietWindow,
          join: m in assoc(w, :machine),
          where: is_nil(w.ended_at) and w.until > ^now and not is_nil(w.silent_at),
          where: m.last_seen_at > w.silent_at,
          select: w
      )

    for w <- waiting, reported?(w) do
      Repo.update_all(from(q in QuietWindow, where: q.id == ^w.id),
        set: [ended_at: now, ended_by: "machine back"]
      )
    end
  end

  defp reported?(%QuietWindow{machine_id: id, silent_at: since}) do
    not Repo.exists?(
      from c in Check,
        join: s in assoc(c, :service),
        where: s.machine_id == ^id and s.watched and c.type in ^@reported,
        where: is_nil(c.checked_at) or c.checked_at <= ^since
    )
  end
end
