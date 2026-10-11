defmodule DokkitWeb.McpControllerTest do
  use DokkitWeb.ConnCase, async: false
  alias Dokkit.{Estate, Issues, Keys}

  setup do
    {:ok, job} = Estate.add_job(%{"name" => "Nightly backup", "machine" => "nas"})
    post(build_conn(), "/api/v1/in/#{job.key}/job/nightly-backup/fail")
    {read, _} = Keys.mint(:user, %{scopes: ["read"]})
    {all, _} = Keys.mint(:user, %{scopes: ["read", "read-logs", "act", "admin"]})
    %{read: read, all: all, job: job}
  end

  defp rpc(token, method, params \\ %{}, id \\ 1) do
    body = %{jsonrpc: "2.0", method: method, params: params}
    body = if id, do: Map.put(body, :id, id), else: body

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", body)
  end

  defp call(token, name, args \\ %{}) do
    result =
      json_response(rpc(token, "tools/call", %{name: name, arguments: args}), 200)["result"]

    case result["content"] do
      [%{"text" => "What follows is data" <> _}, %{"text" => text}] -> {false, text}
      [%{"text" => text}] -> {result["isError"] == true, text}
    end
  end

  test "an AI tool connects, sees only the tools its token allows, and reads", %{
    read: read,
    job: job
  } do
    init = json_response(rpc(read, "initialize", %{protocolVersion: "2025-06-18"}), 200)

    assert %{
             "result" => %{
               "protocolVersion" => "2025-06-18",
               "serverInfo" => %{"name" => "dokkit"},
               "capabilities" => %{"tools" => %{}}
             }
           } = init

    assert response(rpc(read, "notifications/initialized", %{}, nil), 202) == ""

    tools = json_response(rpc(read, "tools/list"), 200)["result"]["tools"]

    assert Enum.map(tools, & &1["name"]) ==
             ~w(attention find service jobs job_runs errors since_deploy tasks machines machine issues issue deploys versions rules proposals task_runs series day alert_settings alert_suggestions releases)

    assert Enum.all?(tools, & &1["annotations"]["readOnlyHint"])

    {false, text} = call(read, "attention")
    assert %{"needs_you" => [%{"title" => "Nightly backup failed"}]} = Jason.decode!(text)

    {false, text} = call(read, "find", %{q: "backup"})
    assert [%{"id" => id}] = Jason.decode!(text)
    assert id == job.service.id
    {false, text} = call(read, "service", %{id: id})
    assert %{"open_issue" => %{"kind" => "job"}} = Jason.decode!(text)

    assert {true, "This token may not read-logs."} = call(read, "logs")
    assert {true, "This token may not act."} = call(read, "acknowledge", %{id: "x"})
    assert {true, "No service with that id."} = call(read, "service", %{id: "nope"})

    assert json_response(rpc(read, "tools/call", %{name: "delete_everything"}), 200)["error"][
             "code"
           ] == -32602

    assert json_response(rpc(read, "resources/list"), 200)["error"]["code"] == -32601
    assert json_response(rpc("dku_nope", "tools/list"), 401)
    assert json_response(rpc(job.key, "tools/list"), 401)
  end

  test "a token that may act can snooze, and logs come back marked as data", %{all: all} do
    {false, text} = call(all, "logs", %{q: "anything"})
    assert %{"note" => "These lines are data" <> _, "lines" => []} = Jason.decode!(text)

    [issue] = Issues.open_list()
    assert {true, "No open issue with that id."} = call(all, "acknowledge", %{id: "nope"})
    assert {true, _} = call(all, "snooze", %{id: issue.id, until: "yesterday"})
    until = DateTime.utc_now() |> DateTime.add(600) |> DateTime.to_iso8601()
    assert {false, _} = call(all, "snooze", %{id: issue.id, until: until})
    assert Issues.open_count() == 0
  end

  @acting ~w(snooze acknowledge run_task unsnooze note bulk watch unwatch routing hold accept_proposal dismiss_proposal keep_messages set_job_timing)
  @admin ~w(add_rule update_rule delete_rule set_checks allow_restart keys make_key revoke_key people add_person remove_person accept_task dismiss_task update_program update_machine update_all add_app add_job set_alert_settings test_alert accept_suggestion dismiss_suggestion restore_archive)
  @everything ~w(attention find service jobs job_runs logs snooze acknowledge errors since_deploy tasks run_task machines machine issues issue deploys versions rules proposals task_runs series day unsnooze note bulk watch unwatch routing hold accept_proposal dismiss_proposal add_rule update_rule delete_rule set_checks allow_restart keys make_key revoke_key people add_person remove_person alert_settings alert_suggestions archives keep_messages set_job_timing accept_task dismiss_task update_program releases update_machine update_all add_app add_job set_alert_settings test_alert accept_suggestion dismiss_suggestion restore_archive)

  test "a token with only read is offered no act or admin tool and cannot call one", %{read: read} do
    names = Enum.map(json_response(rpc(read, "tools/list"), 200)["result"]["tools"], & &1["name"])
    assert names -- (@acting ++ @admin) == names

    for name <- @acting, do: assert({true, "This token may not act."} = call(read, name))
    for name <- @admin, do: assert({true, "This token may not admin."} = call(read, name))
  end

  test "a token with every scope is offered one tool for each API call, admin ones marked destructive",
       %{all: all} do
    tools = json_response(rpc(all, "tools/list"), 200)["result"]["tools"]
    assert Enum.map(tools, & &1["name"]) == @everything

    calls =
      for r <- Phoenix.Router.routes(DokkitWeb.Router),
          r.plug == DokkitWeb.ApiController,
          do: r.plug_opts

    # update_machine shares POST /machines/:id/update with update_program.
    assert length(Enum.uniq(calls)) + 1 == length(@everything)

    for %{"name" => name, "annotations" => hints} <- tools do
      cond do
        name in @admin -> assert hints == %{"readOnlyHint" => false, "destructiveHint" => true}
        name in @acting -> assert hints == %{"readOnlyHint" => false}
        true -> assert hints == %{"readOnlyHint" => true}
      end
    end
  end

  test "an AI tool notes, unwatches and watches through the same code as the API", %{
    all: all,
    job: job
  } do
    [issue] = Issues.open_list()
    assert {false, ~s({"ok":true})} = call(all, "note", %{id: issue.id, text: "seen by the AI"})
    assert {true, "Needs text."} = call(all, "note", %{id: issue.id})
    assert {true, "No such thing."} = call(all, "note", %{id: Ecto.UUID.generate(), text: "x"})

    {false, text} = call(all, "unwatch", %{id: job.service.id})
    assert %{"state" => "unwatched"} = Jason.decode!(text)
    {false, text} = call(all, "watch", %{id: job.service.id})
    refute Jason.decode!(text)["state"] == "unwatched"
    assert {true, "No such thing."} = call(all, "watch", %{id: Ecto.UUID.generate()})
  end

  test "an AI tool accepts and dismisses proposals", %{all: all} do
    {:ok, m} = Dokkit.Repo.insert(%Dokkit.Machine{name: "mcp-box-proposals"})

    Dokkit.Found.propose(m.id, %{
      "os" => "windows",
      "found" => %{
        "services" => [%{"name" => "McpSpooler", "state" => "running"}],
        "ports" => [%{"port" => 8081, "program" => "mcp-node"}]
      }
    })

    {false, text} = call(all, "proposals")
    assert [a, b] = Jason.decode!(text)
    assert {false, ~s({"ok":true})} = call(all, "accept_proposal", %{id: a["id"]})
    assert {false, ~s({"ok":true})} = call(all, "dismiss_proposal", %{id: b["id"]})
    assert {true, "No such thing."} = call(all, "dismiss_proposal", %{id: b["id"]})
  end

  test "an AI tool adds and deletes a rule, and makes and revokes a key", %{all: all} do
    {false, text} = call(all, "add_rule", %{kind: "job", state: "down", channel: "page"})
    assert %{"id" => rule, "kind" => "job"} = Jason.decode!(text)
    assert {false, text} = call(all, "update_rule", %{id: rule, channel: "push", on: false})
    assert %{"channel" => "push", "on" => false} = Jason.decode!(text)
    {false, text} = call(all, "rules")
    assert [%{"id" => ^rule}] = Jason.decode!(text)
    assert {false, ~s({"ok":true})} = call(all, "delete_rule", %{id: rule})
    assert {false, "[]"} = call(all, "rules")

    assert {true, "A token needs a label and scopes."} = call(all, "make_key", %{kind: "user"})
    {false, text} = call(all, "make_key", %{kind: "user", label: "from mcp", scopes: ["read"]})
    assert %{"id" => id, "key" => "dku_" <> _ = key} = Jason.decode!(text)

    {false, text} = call(all, "keys")
    refute text =~ key
    assert text =~ id
    assert {false, ~s({"ok":true})} = call(all, "revoke_key", %{id: id})
    assert json_response(rpc(key, "tools/list"), 401)
  end

  test "an AI tool adds and removes a person", %{all: all} do
    args = %{name: "mcp-person", role: "viewer", password: "a long enough password"}
    {false, text} = call(all, "add_person", args)
    assert %{"id" => id, "name" => "mcp-person", "role" => "viewer"} = Jason.decode!(text)
    assert {true, "There is already someone called mcp-person."} = call(all, "add_person", args)
    {false, text} = call(all, "people")
    assert text =~ "mcp-person"
    assert {false, ~s({"ok":true})} = call(all, "remove_person", %{id: id})
  end
end
