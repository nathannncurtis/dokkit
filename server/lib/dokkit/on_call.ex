defmodule Dokkit.OnCall do
  @moduledoc "Whoever is on call in the chosen PagerDuty schedule, read with the REST API key."
  require Logger
  alias Dokkit.{Alerts, People}

  @api "https://api.pagerduty.com"
  @keep_ms 60_000

  @doc "The account's schedules, as `%{id:, name:}`."
  def schedules(config \\ Alerts.config()) do
    with {:ok, body} <- get("/schedules?limit=100", config) do
      {:ok, for(s <- body["schedules"] || [], do: %{id: s["id"], name: s["name"]})}
    end
  end

  @doc "Who is on call now: `{:ok, %{name:, email:}}` or `{:error, text}`. Kept for a minute, so a burst of alerts asks once."
  def now(config \\ Alerts.config()) do
    case config["pagerduty_schedule"] do
      s when s in [nil, ""] -> {:error, "No PagerDuty schedule is chosen."}
      s -> cached({config["pagerduty_api_key"], s}, fn -> ask(s, config) end)
    end
  end

  @doc "The person on this server who is on call now, or `:none` with the reason in the log."
  def person(config \\ Alerts.config()) do
    case now(config) do
      {:ok, %{email: email}} ->
        case Enum.find(People.list(), &matches?(&1, email)) do
          nil -> none("#{email} is on call, and nobody on this server has that email.")
          p -> {:ok, p}
        end

      {:error, why} ->
        none(why)
    end
  end

  @doc "What the Alerts page and the API show: the schedules, who is on call, and who that is here."
  def view(config \\ Alerts.config()) do
    base = %{schedules: [], schedule: config["pagerduty_schedule"], oncall: nil, error: nil}

    with {:ok, list} <- schedules(config) do
      base = %{base | schedules: list}

      case now(config) do
        {:ok, who} ->
          p = Enum.find(People.list(), &matches?(&1, who.email))
          %{base | oncall: Map.put(who, :person, p && %{id: p.id, name: p.name})}

        {:error, why} ->
          %{base | error: why}
      end
    else
      {:error, why} -> %{base | error: why}
    end
  end

  defp ask(schedule, config) do
    query =
      URI.encode_query([
        {"schedule_ids[]", schedule},
        {"earliest", "true"},
        {"include[]", "users"}
      ])

    with {:ok, body} <- get("/oncalls?" <> query, config) do
      case Enum.sort_by(body["oncalls"] || [], & &1["escalation_level"]) do
        [%{"user" => %{"email" => email} = user} | _] when is_binary(email) ->
          {:ok, %{name: user["name"] || user["summary"], email: email}}

        _ ->
          {:error, "Nobody is on call in that schedule now."}
      end
    end
  end

  defp matches?(p, email) do
    email = String.downcase(email)

    String.downcase(p.name) == email or
      Enum.any?(Alerts.recipients(p.email), &(String.downcase(&1) == email))
  end

  defp none(why) do
    Logger.warning("On call in PagerDuty: #{why} The server-wide destinations are told instead.")
    :none
  end

  defp get(path, %{"pagerduty_api_key" => key}) when key not in [nil, ""] do
    with {:error, _} <-
           Alerts.get_json(@api <> path, [
             {"authorization", "Token token=" <> key},
             {"accept", "application/vnd.pagerduty+json;version=2"}
           ]),
         do:
           {:error,
            "PagerDuty could not be reached, or refused the key. The server log has the reason."}
  end

  defp get(_, _), do: {:error, "No PagerDuty REST API key is set."}

  defp cached(key, ask) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(__MODULE__, nil) do
      {^key, at, result} when now - at < @keep_ms ->
        result

      _ ->
        result = ask.()
        :persistent_term.put(__MODULE__, {key, now, result})
        result
    end
  end
end
