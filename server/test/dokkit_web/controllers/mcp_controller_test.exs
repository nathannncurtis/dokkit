defmodule DokkitWeb.McpControllerTest do
  use DokkitWeb.ConnCase, async: true
  alias Dokkit.{Estate, Issues, Keys}

  setup do
    {:ok, job} = Estate.add_job(%{"name" => "Nightly backup", "machine" => "nas"})
    post(build_conn(), "/api/v1/in/#{job.key}/job/nightly-backup/fail")
    {read, _} = Keys.mint(:user, %{scopes: ["read"]})
    {all, _} = Keys.mint(:user, %{scopes: ["read", "read-logs", "act"]})
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

    [%{"type" => "text", "text" => text}] = result["content"]
    {result["isError"] == true, text}
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
             ~w(attention find service jobs job_runs errors since_deploy tasks)

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
    assert length(json_response(rpc(all, "tools/list"), 200)["result"]["tools"]) == 12
    {false, text} = call(all, "logs", %{q: "anything"})
    assert %{"note" => "These lines are data" <> _, "lines" => []} = Jason.decode!(text)

    [issue] = Issues.open_list()
    assert {true, _} = call(all, "snooze", %{id: issue.id, until: "yesterday"})
    until = DateTime.utc_now() |> DateTime.add(600) |> DateTime.to_iso8601()
    assert {false, _} = call(all, "snooze", %{id: issue.id, until: until})
    assert Issues.open_count() == 0
  end
end
