defmodule DokkitWeb.GapsTest do
  # The calls that were once only in the interface: each as an API route, then as an MCP tool.
  # Not async: alert settings and the program folder are global.
  use DokkitWeb.ConnCase, async: false
  alias Dokkit.{Alerts, Estate, Keys, Machine, Repo}

  setup do
    {:ok, job} =
      Estate.add_job(%{"name" => "Nightly backup", "machine" => "nas", "schedule" => "0 1 * * *"})

    {read, _} = Keys.mint(:user, %{scopes: ["read"]})
    {act, _} = Keys.mint(:user, %{scopes: ["read", "read-logs", "act"]})
    {ops, _} = Keys.mint(:user, %{scopes: ["admin"]})
    {all, _} = Keys.mint(:user, %{scopes: ["read", "read-logs", "act", "admin"]})
    %{job: job, read: read, act: act, ops: ops, all: all}
  end

  defp call(method, path, token, body \\ %{}) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> dispatch(@endpoint, method, "/api/v1" <> path, body)
  end

  defp tool(token, name, args \\ %{}) do
    body = %{jsonrpc: "2.0", id: 1, method: "tools/call", params: %{name: name, arguments: args}}

    result =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", body)
      |> json_response(200)
      |> Map.fetch!("result")

    case result["content"] do
      [%{"text" => "What follows is data" <> _}, %{"text" => text}] -> {false, text}
      [%{"text" => text}] -> {result["isError"] == true, text}
    end
  end

  defp code(conn, status), do: json_response(conn, status)["error"]["code"]

  defp vault, do: Repo.insert!(%Machine{name: "vault", kind: :enrolled})

  defp snoozed_often do
    {:ok, a} = Estate.add_job(%{"name" => "Flaky sync", "machine" => "attic"})
    {:ok, b} = Estate.add_job(%{"name" => "Noisy probe", "machine" => "attic"})

    for job <- [a, b], round <- 1..6 do
      if round > 1, do: post(build_conn(), "/api/v1/in/#{job.key}/job/#{job.service.slug}/ok")
      post(build_conn(), "/api/v1/in/#{job.key}/job/#{job.service.slug}/fail")
    end

    mine = [a.service.id, b.service.id]

    Dokkit.Issues.snooze(
      for(i <- Dokkit.Issues.open_list(), i.service_id in mine, do: i.id),
      3600
    )

    Alerts.suggestions()
  end

  defp archived(dir) do
    machine = Repo.insert!(%Machine{name: "attic-logs"})
    at = ~U[2020-01-15 10:00:00.000000Z]
    # The partition is made and dropped inside this test, so it is not remembered as there.
    :persistent_term.erase({Dokkit.Logs, {2020, 1}})
    on_exit(fn -> :persistent_term.erase({Dokkit.Logs, {2020, 1}}) end)
    Dokkit.Logs.ensure_partition(at)

    Repo.insert_all(Dokkit.Log, [
      %{
        at: at,
        received_at: at,
        level: "error",
        msg: "an old line",
        fields: %{},
        cut: false,
        machine_id: machine.id
      }
    ])

    Application.put_env(:dokkit, :archive, dir)
    on_exit(fn -> Application.delete_env(:dokkit, :archive) end)
    [_] = Dokkit.Logs.archive(dir, ~D[2026-10-06])
  end

  defp programs(dir) do
    Application.put_env(:dokkit, :programs, dir)
    on_exit(fn -> Application.delete_env(:dokkit, :programs) end)
    File.write!(Path.join(dir, "version.txt"), "0.2.0\n")
  end

  describe "routes" do
    test "PUT /services/:id/messages", %{job: job, read: read, act: act} do
      path = "/services/#{job.service.id}/messages"
      assert json_response(call(:put, path, read, %{keep: true}), 403)
      assert %{"keep_messages" => true} = json_response(call(:put, path, act, %{keep: true}), 200)

      assert %{"keep_messages" => false} =
               json_response(call(:put, path, act, %{keep: false}), 200)

      assert code(call(:put, path, act, %{keep: "yes"}), 422) == "bad_keep"
      assert json_response(call(:put, "/services/nope/messages", act, %{keep: true}), 404)
    end

    test "POST /apps makes an app under no one machine, with its key", %{act: act, ops: ops} do
      assert json_response(call(:post, "/apps", act, %{name: "Order Fetcher"}), 403)

      assert %{"id" => id, "slug" => "order-fetcher", "key" => "dka_" <> _} =
               json_response(call(:post, "/apps", ops, %{name: "Order Fetcher"}), 200)

      app = Dokkit.Repo.get!(Dokkit.Service, id) |> Dokkit.Repo.preload(:machine)
      assert {app.kind, app.machine.name, app.machine.kind} == {:app, "Apps", :group}
      assert code(call(:post, "/apps", ops, %{name: "Order Fetcher"}), 422) == "bad_app"
      assert code(call(:post, "/apps", ops, %{name: " "}), 422) == "bad_app"
    end

    test "POST /jobs", %{act: act, ops: ops, read: read} do
      body = %{name: "Weekly report", machine: "nas", schedule: "0 2 * * 1", grace: "20m"}
      assert json_response(call(:post, "/jobs", act, body), 403)

      assert %{"id" => id, "key" => "dka_" <> _ = key, "ping" => %{"ok" => ok}} =
               json_response(call(:post, "/jobs", ops, body), 200)

      assert ok =~ "/api/v1/in/#{key}/job/weekly-report/ok"

      assert %{"items" => jobs} = json_response(call(:get, "/jobs", read), 200)
      assert %{"grace" => "20m", "max_runtime" => nil} = Enum.find(jobs, &(&1["id"] == id))

      assert code(call(:post, "/jobs", ops, %{name: "No machine"}), 422) == "bad_job"
      assert code(call(:post, "/jobs", ops, %{body | grace: 20}), 422) == "bad_job"
      assert code(call(:post, "/jobs", ops, %{body | name: "Weekly report"}), 422) == "bad_job"
    end

    test "PUT /jobs/:id/timing", %{job: job, read: read, act: act} do
      path = "/jobs/#{job.service.id}/timing"
      assert json_response(call(:put, path, read, %{grace: "5m"}), 403)

      assert %{"grace" => "45m", "max_runtime" => "2h"} =
               json_response(call(:put, path, act, %{grace: "45m", max_runtime: "2h"}), 200)

      assert code(call(:put, path, act, %{grace: "soon"}), 422) == "bad_timing"
      assert code(call(:put, path, act, %{grace: 5}), 422) == "bad_timing"
      assert json_response(call(:put, "/jobs/nope/timing", act, %{}), 404)
    end

    @tag :tmp_dir
    test "POST /machines/:id/update", %{act: act, ops: ops, read: read, tmp_dir: dir} do
      machine = vault()
      path = "/machines/#{machine.id}/update"
      assert json_response(call(:post, path, act), 403)
      assert code(call(:post, path, ops), 422) == "no_program"

      programs(dir)
      assert %{"run" => _} = json_response(call(:post, path, ops), 200)
      assert json_response(call(:post, "/machines/nope/update", ops), 404)

      assert %{"program" => %{"held" => "0.2.0"}} =
               json_response(call(:get, "/versions", read), 200)
    end

    test "GET and PUT /alerts", %{read: read, act: act, ops: ops} do
      assert %{"pagerduty_key" => "not set", "webhook_url" => "not set", "down" => "page"} =
               json_response(call(:get, "/alerts", read), 200)

      change = %{down: "push", pagerduty_key: "S3CRET", webhook_url: "https://hook.example/x"}
      assert json_response(call(:put, "/alerts", act, change), 403)

      assert %{"down" => "push", "pagerduty_key" => "set", "webhook_url" => "set"} =
               body = json_response(call(:put, "/alerts", ops, change), 200)

      shown = inspect([body, json_response(call(:get, "/alerts", read), 200)])
      refute shown =~ "S3CRET"
      refute shown =~ "hook.example"
      assert %{"pagerduty_key" => "S3CRET"} = Alerts.config()

      for bad <- [
            %{night_from: "late"},
            %{webhook_url: "http://x.example"},
            %{down: "bogus"},
            %{disk_limit: 5}
          ] do
        assert code(call(:put, "/alerts", ops, bad), 422) == "bad_settings"
      end
    end

    test "POST /alerts/test", %{act: act, ops: ops} do
      Alerts.save(%{"webhook_url" => "https://hook.example/x"})
      Req.Test.stub(Alerts, &Plug.Conn.send_resp(&1, 200, "ok"))

      assert json_response(call(:post, "/alerts/test", act, %{channel: "webhook"}), 403)

      assert %{"ok" => true} =
               json_response(call(:post, "/alerts/test", ops, %{channel: "webhook"}), 200)

      assert code(call(:post, "/alerts/test", ops, %{channel: "pigeon"}), 422) == "bad_channel"

      assert %{
               "error" => %{
                 "code" => "send_failed",
                 "message" => "PagerDuty has no routing key yet."
               }
             } =
               json_response(call(:post, "/alerts/test", ops, %{channel: "page"}), 422)
    end

    test "alert suggestions are read, accepted and dismissed", %{read: read, act: act, ops: ops} do
      [one, two] = snoozed_often()

      assert %{"items" => [%{"id" => _, "count" => 6}, _]} =
               json_response(call(:get, "/alerts/suggestions", read), 200)

      assert json_response(call(:post, "/alerts/suggestions/#{one.id}/accept", act), 403)
      assert json_response(call(:post, "/alerts/suggestions/#{one.id}/accept", ops), 200)
      assert Repo.get!(Dokkit.Service, one.service_id).route_down == "digest"
      assert json_response(call(:post, "/alerts/suggestions/#{two.id}/dismiss", ops), 200)
      assert json_response(call(:post, "/alerts/suggestions/#{two.id}/dismiss", ops), 404)
      assert %{"items" => []} = json_response(call(:get, "/alerts/suggestions", read), 200)
    end

    @tag :tmp_dir
    test "GET /logs/archives and POST /logs/archives/:name/restore", %{
      read: read,
      act: act,
      ops: ops,
      tmp_dir: dir
    } do
      assert code(call(:post, "/logs/archives/logs-2020-01/restore", ops), 404) == "not_found"
      archived(dir)

      assert json_response(call(:get, "/logs/archives", read), 403)

      assert %{"items" => [%{"name" => "logs-2020-01"} = month]} =
               json_response(call(:get, "/logs/archives", act), 200)

      refute Map.has_key?(month, "path")

      assert json_response(call(:post, "/logs/archives/logs-2020-01/restore", act), 403)

      assert %{"ok" => true, "lines" => 1} =
               json_response(call(:post, "/logs/archives/logs-2020-01/restore", ops), 200)

      assert code(call(:post, "/logs/archives/..%2Fx/restore", ops), 404) == "not_found"
    end
  end

  describe "tools" do
    test "keep_messages", %{job: job, all: all} do
      assert {false, text} = tool(all, "keep_messages", %{id: job.service.id, keep: true})
      assert %{"keep_messages" => true} = Jason.decode!(text)

      assert {true, "keep must be a boolean."} =
               tool(all, "keep_messages", %{id: job.service.id, keep: "yes"})

      assert {true, "keep is true or false."} = tool(all, "keep_messages", %{id: job.service.id})
    end

    test "add_job and set_job_timing", %{all: all} do
      assert {false, text} = tool(all, "add_job", %{name: "Weekly report", machine: "nas"})
      assert %{"id" => id, "key" => "dka_" <> _} = Jason.decode!(text)

      assert {true, "A job needs a name and the machine it runs on."} =
               tool(all, "add_job", %{name: "x"})

      assert {false, text} = tool(all, "set_job_timing", %{id: id, grace: "10m"})
      assert %{"grace" => "10m"} = Jason.decode!(text)

      assert {true, "Write times as a number and a unit: 30m, 2h, 1d."} =
               tool(all, "set_job_timing", %{id: id, grace: "soon"})
    end

    @tag :tmp_dir
    test "update_program", %{all: all, tmp_dir: dir} do
      machine = vault()

      assert {true, "This server holds no program for machines to fetch."} =
               tool(all, "update_program", %{id: machine.id})

      programs(dir)
      assert {false, text} = tool(all, "update_program", %{id: machine.id})
      assert %{"run" => _} = Jason.decode!(text)
      assert {true, "No such thing."} = tool(all, "update_program", %{id: "nope"})
    end

    test "alert_settings, set_alert_settings and test_alert", %{all: all} do
      assert {false, text} = tool(all, "alert_settings")
      assert %{"smtp_password" => "not set"} = Jason.decode!(text)

      assert {false, text} =
               tool(all, "set_alert_settings", %{
                 down: "push",
                 smtp_password: "S3CRET",
                 ntfy_url: "https://ntfy.example/t"
               })

      assert %{"down" => "push", "smtp_password" => "set"} = Jason.decode!(text)
      refute text =~ "S3CRET"

      assert {true, "webhook: The address must start with https://."} =
               tool(all, "set_alert_settings", %{webhook_url: "http://x.example"})

      assert {true, "down must be a string."} = tool(all, "set_alert_settings", %{down: 5})

      Req.Test.stub(Alerts, &Plug.Conn.send_resp(&1, 200, "ok"))
      assert {false, ~s({"ok":true})} = tool(all, "test_alert", %{channel: "push"})

      assert {true, "PagerDuty has no routing key yet."} =
               tool(all, "test_alert", %{channel: "page"})
    end

    test "alert_suggestions, accept_suggestion and dismiss_suggestion", %{all: all} do
      [one, two] = snoozed_often()
      assert {false, text} = tool(all, "alert_suggestions")
      assert [%{"count" => 6}, _] = Jason.decode!(text)
      assert {false, ~s({"ok":true})} = tool(all, "accept_suggestion", %{id: one.id})
      assert {false, ~s({"ok":true})} = tool(all, "dismiss_suggestion", %{id: two.id})
      assert {true, "No such thing."} = tool(all, "dismiss_suggestion", %{id: two.id})
      assert {false, "[]"} = tool(all, "alert_suggestions")
    end

    @tag :tmp_dir
    test "archives and restore_archive", %{all: all, tmp_dir: dir} do
      assert {true, "No such thing."} = tool(all, "restore_archive", %{name: "logs-2020-01"})
      archived(dir)
      assert {false, text} = tool(all, "archives")
      assert [%{"name" => "logs-2020-01"}] = Jason.decode!(text)
      assert {false, text} = tool(all, "restore_archive", %{name: "logs-2020-01"})
      assert %{"ok" => true, "lines" => 1} = Jason.decode!(text)
    end
  end
end
