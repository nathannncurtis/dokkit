defmodule Dokkit.Demo.Seats do
  @moduledoc "The public demo's seats and the line for them, as plain data. Times are milliseconds."

  @limits %{
    seats: 80,
    per_address: 3,
    warn_after: 5 * 60_000,
    end_after: 6 * 60_000,
    gone_after: 2 * 60_000,
    long_after: 20 * 60_000,
    hold: 2 * 60_000,
    poll_gone: 30_000,
    here_max: 2,
    recent: 3
  }

  defstruct limits: @limits, seats: %{}, line: [], freed: []

  def new(limits \\ %{}), do: %__MODULE__{limits: Map.merge(@limits, Map.new(limits))}

  def take(s, address, now) do
    cond do
      count(s, address) >= s.limits.per_address ->
        {:address_limit, s}

      free(s) > 0 and s.line == [] ->
        id = token()
        {{:seat, id}, put_in(s.seats[id], seat(address, now))}

      true ->
        ticket = %{id: token(), address: address, polled: now, offered: nil}
        {{:line, ticket.id}, offer(%{s | line: s.line ++ [ticket]}, now)}
    end
  end

  @doc "Where a ticket stands: `{:waiting, place}`, `{:turn, until}` or `:gone`."
  def poll(s, id, now) do
    case Enum.find_index(s.line, &(&1.id == id)) do
      nil ->
        {:gone, s}

      i ->
        s = update_in(s.line, &List.update_at(&1, i, fn t -> %{t | polled: now} end))
        t = Enum.at(s.line, i)

        if t.offered,
          do: {{:turn, t.offered + s.limits.hold}, s},
          else: {{:waiting, Enum.count(Enum.take(s.line, i), &is_nil(&1.offered)) + 1}, s}
    end
  end

  def claim(s, id, now) do
    case Enum.find(s.line, &(&1.id == id and &1.offered)) do
      nil ->
        {:gone, s}

      t ->
        seat_id = token()
        s = %{s | line: Enum.reject(s.line, &(&1.id == id))}
        {{:seat, seat_id}, put_in(s.seats[seat_id], seat(t.address, now))}
    end
  end

  def seated?(s, id), do: Map.has_key?(s.seats, id)

  @doc "An open page of the seat. `:gone` when the seat is no longer held."
  def attach(s, id, pid) do
    if seated?(s, id),
      do:
        {:ok, update_in(s.seats[id], &%{&1 | pids: MapSet.put(&1.pids, pid), alone_since: nil})},
      else: {:gone, s}
  end

  def detach(s, pid, now) do
    seats =
      Map.new(s.seats, fn {id, seat} ->
        pids = MapSet.delete(seat.pids, pid)
        alone = if MapSet.size(pids) == 0, do: seat.alone_since || now
        {id, %{seat | pids: pids, alone_since: alone}}
      end)

    %{s | seats: seats}
  end

  @doc "Something done in Dokkit. It counts only when unlike the seat's last few actions."
  def act(s, id, action, now) do
    case s.seats[id] do
      %{recent: recent} = seat ->
        if action in recent do
          s
        else
          seat = %{
            seat
            | recent: Enum.take([action | recent], s.limits.recent),
              active: now,
              here: 0,
              warned: nil
          }

          put_in(s.seats[id], seat)
        end

      nil ->
        s
    end
  end

  @doc "The Still there? button: it keeps the seat only a couple of times in a row."
  def here(s, id, now) do
    case s.seats[id] do
      %{here: n} = seat when n < s.limits.here_max ->
        {:ok, put_in(s.seats[id], %{seat | here: n + 1, active: now, warned: nil})}

      _ ->
        {:no, s}
    end
  end

  def leave(s, id, now) do
    if seated?(s, id),
      do: %{s | seats: Map.delete(s.seats, id)} |> stamp_freed(1, now) |> offer(now),
      else: s
  end

  @doc """
  Moves time on. Returns what the open pages must be told: `{:warn, pids, ends_at, spot}`,
  `{:away, pids, reason}`, and the new state.
  """
  def tick(s, now) do
    l = s.limits

    line =
      Enum.reject(
        s.line,
        &(now - &1.polled > l.poll_gone or (&1.offered && now - &1.offered > l.hold))
      )

    s = %{s | line: line, freed: Enum.filter(s.freed, &(now - &1 < 5 * 60_000))}

    {away, kept} =
      Enum.split_with(s.seats, fn {_, seat} ->
        now - seat.active >= l.end_after or
          (seat.alone_since && now - seat.alone_since >= l.gone_after)
      end)

    events = for {_, seat} <- away, do: {:away, seat.pids, reason(seat, now, l)}
    s = %{s | seats: Map.new(kept)} |> stamp_freed(length(away), now)

    waiting = Enum.count(s.line, &is_nil(&1.offered))

    long =
      if free(s) - waiting < 0,
        do:
          s.seats
          |> Enum.filter(fn {_, seat} -> now - seat.taken >= l.long_after end)
          |> Enum.sort_by(fn {_, seat} -> seat.taken end)
          |> Enum.take(waiting - max(free(s), 0)),
        else: []

    events = events ++ for({_, seat} <- long, do: {:away, seat.pids, :long})

    s =
      %{s | seats: Map.drop(s.seats, Enum.map(long, &elem(&1, 0)))}
      |> stamp_freed(length(long), now)

    {warns, seats} =
      Enum.map_reduce(s.seats, %{}, fn {id, seat}, acc ->
        if now - seat.active >= l.warn_after and is_nil(seat.warned) do
          seat = %{seat | warned: {:rand.uniform(70) + 5, :rand.uniform(60) + 10}}
          {[{:warn, seat.pids, seat.active + l.end_after, seat.warned}], Map.put(acc, id, seat)}
        else
          {[], Map.put(acc, id, seat)}
        end
      end)

    {events ++ List.flatten(warns), offer(%{s | seats: seats}, now)}
  end

  def stats(s), do: %{taken: map_size(s.seats), seats: s.limits.seats, freed: length(s.freed)}

  def warned?(s, id), do: match?(%{warned: {_, _}}, s.seats[id])

  defp reason(seat, now, l),
    do: if(seat.alone_since && now - seat.alone_since >= l.gone_after, do: :gone, else: :idle)

  defp offer(s, now) do
    {line, _} =
      Enum.map_reduce(s.line, free(s) - Enum.count(s.line, & &1.offered), fn t, left ->
        if is_nil(t.offered) and left > 0, do: {%{t | offered: now}, left - 1}, else: {t, left}
      end)

    %{s | line: line}
  end

  defp free(s), do: s.limits.seats - map_size(s.seats)

  defp count(s, address),
    do:
      Enum.count(s.seats, fn {_, x} -> x.address == address end) +
        Enum.count(s.line, &(&1.address == address))

  defp seat(address, now),
    do: %{
      address: address,
      taken: now,
      active: now,
      recent: [],
      here: 0,
      pids: MapSet.new(),
      alone_since: now,
      warned: nil
    }

  defp stamp_freed(s, n, now),
    do: %{s | freed: List.duplicate(now, n) ++ s.freed}

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
