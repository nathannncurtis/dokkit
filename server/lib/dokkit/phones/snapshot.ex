defmodule Dokkit.Phones.Snapshot do
  @moduledoc "What a phone shows, built from the same functions the API answers with, without keys, people's destinations or settings."
  alias Dokkit.{Numbers, Read}

  @max_gzip 1_500_000
  @never ~w(routing restart keep_messages silent thresholds config key token password secret smtp_password
            pagerduty_key ntfy_token ntfy_url pushover_token pushover_user twilio_token twilio_sid
            webhook_url heartbeat_url email_to smtp_user)

  def json(counter, now, opts \\ []), do: counter |> build(now, opts) |> Jason.encode!()

  @doc "A snapshot built earlier, stamped with its counter and time, as JSON."
  def stamp(doc, counter, now) do
    doc
    |> put_in(["server", "counter"], counter)
    |> put_in(["server", "made_at"], now |> DateTime.truncate(:second) |> DateTime.to_iso8601())
    |> Jason.encode!()
  end

  @doc "Changes when what a phone would see changes: the snapshot without its counter and time, the phones and the relay."
  def fingerprint(doc \\ build(0, DateTime.utc_now())) do
    doc = update_in(doc, ["server"], &Map.drop(&1, ~w(counter made_at)))

    r = Dokkit.Phones.relay()
    slots = Enum.map(Dokkit.Phones.list(), & &1.slot)

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({doc, slots, r["address"], r["mailbox"], r["key"]}, [:deterministic])
    )
  end

  @doc "The snapshot as a map with text keys. Logs, then charts, are left out when it would pass 1.5 MB compressed."
  def build(counter, now, opts \\ []) do
    max = Keyword.get(opts, :max, @max_gzip)

    doc =
      %{
        schema: 1,
        server: %{
          name: Dokkit.Phones.server_name(),
          version: "v" <> to_string(Application.spec(:dokkit, :vsn)),
          made_at: now |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          counter: counter,
          left_out: []
        },
        inbox: Read.inbox(),
        machines: machines(),
        services: services(now),
        issues: issues(),
        jobs: Read.jobs()
      }
      |> normalize()
      |> Map.update!("jobs", &strip(&1, ["tail"]))

    doc |> Map.put("logs", logs(doc["issues"])) |> fit(max, ["logs", "chart"])
  end

  defp fit(doc, max, [next | rest]) do
    if byte_size(:zlib.gzip(Jason.encode!(doc))) <= max do
      doc
    else
      doc
      |> leave_out(next)
      |> fit(max, rest)
    end
  end

  defp fit(doc, _, []), do: doc

  defp leave_out(doc, "logs"), do: doc |> Map.put("logs", %{}) |> left("logs")

  defp leave_out(doc, "chart"),
    do:
      doc
      |> Map.update!("services", fn list -> Enum.map(list, &Map.delete(&1, "chart")) end)
      |> left("chart")

  defp left(doc, name), do: update_in(doc, ["server", "left_out"], &(&1 ++ [name]))

  defp normalize(map), do: map |> Jason.encode!() |> Jason.decode!() |> strip(@never)

  defp strip(%{} = map, names),
    do: for({k, v} <- map, k not in names, into: %{}, do: {k, strip(v, names)})

  defp strip(list, names) when is_list(list), do: Enum.map(list, &strip(&1, names))
  defp strip(other, _), do: other

  defp machines do
    for m <- Read.machines(), do: Read.machine(m.id)
  end

  defp services(now) do
    for s <- Read.services(%{}) do
      Read.service(s.id) |> Map.put(:chart, chart(s.id, now))
    end
  end

  defp chart(id, now) do
    case Numbers.names(id) do
      [] ->
        %{metric: nil, values: List.duplicate(nil, 24)}

      [name | _] ->
        points = Numbers.series(id, name, DateTime.add(now, -86_400), now, 24)
        %{metric: name, values: Enum.map(points, & &1.value)}
    end
  end

  defp issues do
    for i <- Read.issues() do
      issue = Read.one_issue(i.id)
      %{issue | history: Enum.take(issue.history, -20), notes: Enum.take(issue.notes, -20)}
    end
  end

  defp logs(issues) do
    for id <- issues |> Enum.map(& &1["service"]) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
        into: %{} do
      %{items: lines} = Read.list(:logs, %{"service" => id, "limit" => 20})
      {id, for(l <- lines, do: %{t: l.t, level: l.level, msg: l.msg})}
    end
    |> normalize()
  end
end
