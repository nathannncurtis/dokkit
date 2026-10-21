defmodule Dokkit.OnCall do
  @moduledoc "Whoever is on call in the chosen PagerDuty schedule, read with the REST API key."
  require Logger
  alias Dokkit.{Alerts, People}

  @api "https://api.pagerduty.com"
  @keep_ms 60_000
  @wait_ms 3_500
  # Short, so a slow PagerDuty cannot hold up the send sweep for long.
  @quick [receive_timeout: 3_000, retry: false]

  def quick, do: @quick

  @doc "The account's schedules, as `%{id:, name:}`."
  def schedules(config \\ Alerts.config()) do
    with {:ok, body} <- get("/schedules?limit=100", config, []) do
      {:ok, for(s <- body["schedules"] || [], do: %{id: s["id"], name: s["name"]})}
    end
  end

  @doc """
  Everyone on call now in the schedule: `{:ok, [%{name:, email:}]}` or `{:error, text}`. An
  answer is kept for a minute and one lookup runs at a time, so a burst of alerts asks once.
  A failure is not kept.
  """
  def now(config \\ Alerts.config()) do
    case config["pagerduty_schedule"] do
      s when s in [nil, ""] -> {:error, "No PagerDuty schedule is chosen."}
      s -> cached({config["pagerduty_api_key"], s}, fn -> ask(s, config) end)
    end
  end

  @doc "The people on this server who are on call now, or `:none` with the reason in the log."
  def people(config \\ Alerts.config()) do
    case now(config) do
      {:ok, users} ->
        case matched(users) do
          [] ->
            none(
              "Nobody on this server has the email of whoever is on call (#{Enum.map_join(users, ", ", & &1.email)})."
            )

          found ->
            {:ok, found}
        end

      {:error, why} ->
        none(why)
    end
  end

  @doc "What the Alerts page and the API show: the schedules, who is on call, and who each is here."
  def view(config \\ Alerts.config()) do
    base = %{schedules: [], schedule: config["pagerduty_schedule"], oncall: [], error: nil}

    with {:ok, list} <- schedules(config) do
      base = %{base | schedules: list}

      case now(config) do
        {:ok, users} ->
          here = People.list()

          oncall =
            for u <- users do
              p = Enum.find(here, &matches?(&1, u.email))
              Map.put(u, :person, p && %{id: p.id, name: p.name})
            end

          %{base | oncall: oncall}

        {:error, why} ->
          %{base | error: why}
      end
    else
      {:error, why} -> %{base | error: why}
    end
  end

  defp matched(users) do
    here = People.list()
    for(u <- users, p <- here, matches?(p, u.email), do: p) |> Enum.uniq_by(& &1.id)
  end

  defp ask(schedule, config) do
    from = DateTime.utc_now()

    query =
      URI.encode_query(%{
        "since" => DateTime.to_iso8601(from),
        "until" => DateTime.to_iso8601(DateTime.add(from, 60))
      })

    with {:ok, body} <- get("/schedules/#{URI.encode(schedule)}/users?" <> query, config, @quick) do
      case for(u <- body["users"] || [], is_binary(u["email"]), do: u) do
        [] ->
          {:error, "Nobody is on call in that schedule now."}

        users ->
          {:ok,
           users
           |> Enum.map(&%{name: &1["name"] || &1["summary"], email: &1["email"]})
           |> Enum.uniq_by(&String.downcase(&1.email))}
      end
    end
  end

  defp matches?(p, email) do
    email = String.downcase(email)

    String.downcase(p.name || "") == email or
      Enum.any?(Alerts.recipients(p.email), &(String.downcase(&1) == email))
  end

  defp none(why) do
    Logger.warning("On call in PagerDuty: #{why} The server-wide destinations are told instead.")
    :none
  end

  defp get(path, %{"pagerduty_api_key" => key}, opts) when key not in [nil, ""] do
    headers = [
      {"authorization", "Token token=" <> key},
      {"accept", "application/vnd.pagerduty+json;version=2"}
    ]

    with {:error, _} <- Alerts.get_json(@api <> path, headers, opts),
         do:
           {:error,
            "PagerDuty could not be reached, or refused the key. The server log has the reason."}
  end

  defp get(_, _, _), do: {:error, "No PagerDuty REST API key is set."}

  defp cached(key, ask) do
    case fresh(key) do
      nil ->
        deadline = System.monotonic_time(:millisecond) + @wait_ms
        locked(key, ask, deadline)

      result ->
        result
    end
  end

  # Whoever finds nothing kept asks; the rest wait for that answer, then fall back.
  defp locked(key, ask, deadline) do
    lock = {__MODULE__, self()}

    if :global.set_lock(lock, [node()], 0) do
      try do
        fresh(key) || keep(key, ask.())
      after
        :global.del_lock(lock, [node()])
      end
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(50)
        fresh(key) || locked(key, ask, deadline)
      else
        {:error, "Another PagerDuty lookup is still running."}
      end
    end
  end

  defp fresh(key) do
    case :persistent_term.get(__MODULE__, nil) do
      {^key, at, result} -> if System.monotonic_time(:millisecond) - at < @keep_ms, do: result
      _ -> nil
    end
  end

  defp keep(key, {:ok, _} = result) do
    :persistent_term.put(__MODULE__, {key, System.monotonic_time(:millisecond), result})
    result
  end

  defp keep(_, result), do: result
end
