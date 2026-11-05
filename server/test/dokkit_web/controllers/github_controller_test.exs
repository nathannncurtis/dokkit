defmodule DokkitWeb.GithubControllerTest do
  use DokkitWeb.ConnCase, async: false
  alias Dokkit.{Alerts, Kev, Repo}

  @secret "example-webhook-secret"

  setup do
    Kev.reset()

    Alerts.save(%{
      "github_secret" => @secret,
      "github_org" => "example-org",
      "github_mail_to" => "alerts@example.com",
      "mail_from" => "dokkit@example.com"
    })

    Req.Test.stub(Alerts, fn conn ->
      Req.Test.json(conn, %{"vulnerabilities" => [%{"cveID" => "CVE-2026-0002"}]})
    end)

    :ok
  end

  defp sign(body),
    do: "sha256=" <> (:crypto.mac(:hmac, :sha256, @secret, body) |> Base.encode16(case: :lower))

  defp deliver(conn, event, payload, signature \\ nil) do
    body = Jason.encode!(payload)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", event)
    |> put_req_header("x-hub-signature-256", signature || sign(body))
    |> post("/hooks/github", body)
  end

  defp dependabot(severity, cve, number \\ 7, extra \\ %{}) do
    %{
      "action" => "created",
      "repository" => %{"full_name" => "example-org/widgets"},
      "alert" => %{
        "number" => number,
        "html_url" => "https://github.com/example-org/widgets/security/dependabot/#{number}",
        "dependency" => %{"package" => %{"name" => "left-pad"}},
        "security_advisory" => %{
          "severity" => severity,
          "cve_id" => cve,
          "summary" => "Prototype pollution"
        },
        "security_vulnerability" => %{"first_patched_version" => %{"identifier" => "1.2.4"}}
      }
    }
    |> Map.merge(extra)
  end

  defp scanning(level, number \\ 3) do
    %{
      "action" => "created",
      "repository" => %{"full_name" => "example-org/widgets"},
      "alert" => %{
        "number" => number,
        "html_url" => "https://github.com/example-org/widgets/security/code-scanning/#{number}",
        "rule" => %{
          "id" => "js/sql-injection",
          "name" => "SQL injection",
          "description" => "Query built from user input",
          "security_severity_level" => level
        }
      }
    }
  end

  test "an unsigned, wrongly signed or secretless request is 401 and sends nothing", %{conn: conn} do
    body = Jason.encode!(dependabot("critical", nil))

    unsigned =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "dependabot_alert")
      |> post("/hooks/github", body)

    assert unsigned.status == 401

    assert deliver(build_conn(), "dependabot_alert", dependabot("critical", nil), "sha256=00").status ==
             401

    Alerts.save(%{"github_secret" => ""})
    assert deliver(build_conn(), "dependabot_alert", dependabot("critical", nil)).status == 401
    refute_received {:mail, _, _, _}
  end

  test "ping answers 200", %{conn: conn} do
    conn = deliver(conn, "ping", %{"zen" => "Keep it logically awesome."})
    assert json_response(conn, 200) == %{"status" => "pong"}
  end

  test "a critical Dependabot alert is mailed in plain words", %{conn: conn} do
    conn = deliver(conn, "dependabot_alert", dependabot("critical", "CVE-2026-0001"))
    assert json_response(conn, 202) == %{"status" => "emailed"}

    assert_received {:mail, "alerts@example.com",
                     "[GitHub] URGENT: left-pad in example-org/widgets", text}

    assert text ==
             Enum.join(
               [
                 "Dependabot alert: Prototype pollution",
                 "Severity: critical (CVE-2026-0001)",
                 "Repository: example-org/widgets",
                 "Fix pull request: none reported. Patched version: 1.2.4",
                 "Link: https://github.com/example-org/widgets/security/dependabot/7"
               ],
               "\n"
             )
  end

  test "a failed send is 502 and leaves the alert unclaimed for a retry", %{conn: conn} do
    Alerts.save(%{"github_mail_to" => ""})
    payload = dependabot("critical", nil)

    assert json_response(deliver(conn, "dependabot_alert", payload), 502) == %{
             "status" => "mail_failed"
           }

    assert Repo.aggregate("github_alerts_sent", :count) == 0

    Alerts.save(%{"github_mail_to" => "alerts@example.com"})

    assert json_response(deliver(build_conn(), "dependabot_alert", payload), 202)["status"] ==
             "emailed"
  end

  test "high is urgent only when the CVE is on the known exploited list", %{conn: conn} do
    listed = deliver(conn, "dependabot_alert", dependabot("high", "CVE-2026-0002", 8))
    assert json_response(listed, 202) == %{"status" => "emailed"}
    assert_received {:mail, _, _, _}

    other = deliver(build_conn(), "dependabot_alert", dependabot("high", "CVE-2026-9999", 9))
    assert json_response(other, 202) == %{"status" => "ignored"}

    none = deliver(build_conn(), "dependabot_alert", dependabot("high", nil, 10))
    assert json_response(none, 202) == %{"status" => "ignored"}
    refute_received {:mail, _, _, _}
  end

  test "medium, other actions and other organisations are accepted without mail", %{conn: conn} do
    assert json_response(deliver(conn, "dependabot_alert", dependabot("medium", nil)), 202) == %{
             "status" => "ignored"
           }

    dismissed = dependabot("critical", nil, 11, %{"action" => "dismissed"})

    assert json_response(deliver(build_conn(), "dependabot_alert", dismissed), 202) == %{
             "status" => "ignored"
           }

    elsewhere =
      dependabot("critical", nil, 12, %{"repository" => %{"full_name" => "other-org/widgets"}})

    assert json_response(deliver(build_conn(), "dependabot_alert", elsewhere), 202) == %{
             "status" => "ignored"
           }

    assert json_response(deliver(build_conn(), "push", %{"ref" => "main"}), 202) == %{
             "status" => "ignored"
           }

    refute_received {:mail, _, _, _}
  end

  test "a critical code scanning alert is mailed with its rule", %{conn: conn} do
    conn = deliver(conn, "code_scanning_alert", scanning("critical"))
    assert json_response(conn, 202) == %{"status" => "emailed"}
    assert_received {:mail, _, "[GitHub] URGENT: SQL injection in example-org/widgets", text}
    assert text =~ "Severity: critical"
    refute text =~ "Fix pull request"

    quiet = deliver(build_conn(), "code_scanning_alert", scanning("high", 4))
    assert json_response(quiet, 202) == %{"status" => "ignored"}
  end

  test "an alert is mailed once, however often it is delivered or reopened", %{conn: conn} do
    payload = dependabot("critical", nil)
    assert json_response(deliver(conn, "dependabot_alert", payload), 202)["status"] == "emailed"

    assert json_response(deliver(build_conn(), "dependabot_alert", payload), 202)["status"] ==
             "duplicate"

    reopened = Map.put(payload, "action", "reopened")

    assert json_response(deliver(build_conn(), "dependabot_alert", reopened), 202)["status"] ==
             "duplicate"

    same_number_other_kind = scanning("critical", 7)

    assert json_response(
             deliver(build_conn(), "code_scanning_alert", same_number_other_kind),
             202
           )["status"] == "emailed"

    assert Repo.aggregate("github_alerts_sent", :count) == 2
    assert_received {:mail, _, _, _}
    assert_received {:mail, _, _, _}
    refute_received {:mail, _, _, _}
  end
end
