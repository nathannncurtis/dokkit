defmodule Dokkit.GithubAlerts do
  @moduledoc """
  Mails an urgent GitHub security alert, once. Urgent is a new or reopened alert that is
  critical, or high with a CVE on CISA's known exploited list. Each alert (repo, number, kind)
  is claimed in the database before it is mailed, so a repeated or forwarded delivery sends nothing.
  """
  import Ecto.Query, only: [from: 2]
  require Logger
  alias Dokkit.{Alerts, Kev, Mail, Repo}

  @kinds %{
    "dependabot_alert" => "Dependabot alert",
    "code_scanning_alert" => "Code scanning alert"
  }
  @actions ~w(created reopened reopened_by_user)

  @doc "True when `signature` is the HMAC-SHA256 of `body` under the configured secret."
  def verify(body, "sha256=" <> hex) when is_binary(body) do
    case Alerts.config()["github_secret"] do
      secret when is_binary(secret) and secret != "" ->
        mac = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
        Plug.Crypto.secure_compare(mac, String.downcase(hex))

      _ ->
        false
    end
  end

  def verify(_, _), do: false

  @doc "`:pong`, `:ignored`, `:duplicate`, `:emailed` or `{:error, text}` for a verified delivery."
  def handle("ping", _), do: :pong

  def handle(event, %{"action" => action} = p)
      when is_map_key(@kinds, event) and action in @actions do
    config = Alerts.config()
    repo = get_in(p, ["repository", "full_name"])
    number = get_in(p, ["alert", "number"])

    if is_binary(repo) and is_integer(number) and in_org?(repo, config["github_org"]) do
      Logger.info("GitHub #{event} #{action} accepted: #{repo} ##{number}")

      if urgent?(event, p["alert"]) do
        Logger.info("GitHub #{event} urgent: #{repo} ##{number}")
        send_once(event, repo, number, p["alert"], config)
      else
        :ignored
      end
    else
      :ignored
    end
  end

  def handle(_, _), do: :ignored

  defp in_org?(_repo, org) when org in [nil, ""], do: true

  defp in_org?(repo, org) do
    orgs = org |> String.split(~r/[,;\s]+/, trim: true) |> Enum.map(&String.downcase/1)
    String.downcase(hd(String.split(repo, "/"))) in orgs
  end

  def severity("dependabot_alert", alert),
    do:
      down(
        get_in(alert, ["security_advisory", "severity"]) ||
          get_in(alert, ["security_vulnerability", "severity"])
      )

  def severity(_, alert), do: down(get_in(alert, ["rule", "security_severity_level"]))

  defp down(s) when is_binary(s), do: String.downcase(s)
  defp down(_), do: nil

  def cve("dependabot_alert", alert) do
    adv = alert["security_advisory"] || %{}

    adv["cve_id"] ||
      Enum.find_value(adv["identifiers"] || [], fn
        %{"type" => "CVE", "value" => v} -> v
        _ -> nil
      end)
  end

  def cve(_, _), do: nil

  def urgent?(event, alert) when is_map(alert) do
    case severity(event, alert) do
      "critical" -> true
      "high" -> Kev.listed?(cve(event, alert))
      _ -> false
    end
  end

  def urgent?(_, _), do: false

  defp send_once(event, repo, number, alert, config) do
    to =
      if config["github_mail_to"] in [nil, ""],
        do: config["email_to"],
        else: config["github_mail_to"]

    row = %{repo: repo, number: number, kind: event, inserted_at: DateTime.utc_now()}

    case Repo.insert_all("github_alerts_sent", [row], on_conflict: :nothing) do
      {0, _} ->
        :duplicate

      {1, _} ->
        case Mail.send(to, subject(event, repo, alert), lines(event, repo, alert), config) do
          :ok ->
            Logger.info("GitHub #{event} emailed: #{repo} ##{number}")
            :emailed

          {:error, why} ->
            Repo.delete_all(
              from s in "github_alerts_sent",
                where: s.repo == ^repo and s.number == ^number and s.kind == ^event
            )

            Logger.warning("GitHub #{event} not emailed: #{repo} ##{number}: #{why}")
            {:error, why}
        end
    end
  end

  defp subject(event, repo, alert), do: "[GitHub] URGENT: #{what(event, alert)} in #{repo}"

  defp what("dependabot_alert", alert),
    do: get_in(alert, ["dependency", "package", "name"]) || "dependency"

  defp what(_, alert),
    do: get_in(alert, ["rule", "name"]) || get_in(alert, ["rule", "id"]) || "rule"

  @doc false
  def lines(event, repo, alert) do
    cve = cve(event, alert)

    [
      "#{@kinds[event]}: #{summary(event, alert)}",
      "Severity: #{severity(event, alert)}#{if cve, do: " (#{cve})"}",
      "Repository: #{repo}",
      fix_line(event, alert),
      "Link: #{alert["html_url"]}"
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp summary("dependabot_alert", alert),
    do: get_in(alert, ["security_advisory", "summary"]) || what("dependabot_alert", alert)

  defp summary(_, alert),
    do: get_in(alert, ["rule", "description"]) || what("code_scanning_alert", alert)

  defp fix_line("dependabot_alert", alert) do
    patched = get_in(alert, ["security_vulnerability", "first_patched_version", "identifier"])

    pr =
      case alert["fix_pull_request_url"] do
        url when is_binary(url) and url != "" -> url
        _ -> "none reported"
      end

    "Fix pull request: #{pr}. Patched version: #{patched || "none yet"}"
  end

  defp fix_line(_, _), do: nil
end
