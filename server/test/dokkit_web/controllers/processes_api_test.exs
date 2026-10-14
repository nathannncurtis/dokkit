defmodule DokkitWeb.ProcessesApiTest do
  use DokkitWeb.ConnCase, async: false
  alias Dokkit.{Intake, Issue, Keys, Machine, Repo, Service}

  @gb 1_073_741_824

  setup do
    machine = Repo.insert!(%Machine{name: "sql1", kind: :enrolled})
    {_, key} = Keys.mint(:machine, %{machine_id: machine.id})
    {read, _} = Keys.mint(:user, %{scopes: ["read"]})
    {act, _} = Keys.mint(:user, %{scopes: ["act"]})
    %{machine: machine, key: key, read: read, act: act}
  end

  defp get_as(token, path) do
    build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get("/api/v1" <> path)
  end

  defp feed(key, items, at \\ DateTime.utc_now()) do
    line = %{
      type: "processes",
      at: DateTime.to_iso8601(at),
      total_memory_bytes: 10 * @gb,
      items: items
    }

    Intake.report(key, nil, Jason.encode!(line), DateTime.utc_now())
  end

  defp items do
    [
      %{
        pid: 1,
        ppid: 0,
        name: "Sqlservr.exe",
        path: "C:/SQL/sqlservr.exe",
        memory_bytes: 5 * @gb,
        cpu_percent: 2.5
      },
      %{
        pid: 2,
        ppid: 1,
        name: "chrome.exe",
        path: "C:/Chrome/chrome.exe",
        memory_bytes: @gb,
        cpu_percent: 40.0
      },
      %{pid: 3, ppid: 1, name: "svchost.exe", path: nil, memory_bytes: 100, cpu_percent: nil}
    ]
  end

  test "the list is sorted, filtered, limited, and carries memory_percent", ctx do
    feed(ctx.key, items())
    path = "/machines/#{ctx.machine.id}/processes"

    body = json_response(get_as(ctx.read, path), 200)
    assert %{"count" => 3, "total_memory_bytes" => total, "at" => at} = body
    assert total == 10 * @gb and is_binary(at)
    assert Enum.map(body["items"], & &1["pid"]) == [1, 2, 3]

    assert [%{"memory_percent" => 50.0}, %{"memory_percent" => 10.0}, %{"memory_percent" => +0.0}] =
             body["items"]

    assert [2, 1, 3] = pids(get_as(ctx.read, path <> "?sort=cpu"))
    assert [1] = pids(get_as(ctx.read, path <> "?q=SQL"))
    assert [2] = pids(get_as(ctx.read, path <> "?q=chrome/chrome"))
    assert [3] = pids(get_as(ctx.read, path <> "?pid=3"))
    assert [] = pids(get_as(ctx.read, path <> "?pid=99"))
    assert [1] = pids(get_as(ctx.read, path <> "?limit=1"))
    assert %{"count" => 3} = json_response(get_as(ctx.read, path <> "?limit=1"), 200)
  end

  defp pids(conn), do: Enum.map(json_response(conn, 200)["items"], & &1["pid"])

  test "nothing received, no such machine, and scopes", ctx do
    assert %{"at" => nil, "items" => []} =
             json_response(get_as(ctx.read, "/machines/#{ctx.machine.id}/processes"), 200)

    assert json_response(get_as(ctx.read, "/machines/#{Ecto.UUID.generate()}/processes"), 404)

    assert json_response(
             get_as(ctx.read, "/machines/#{Ecto.UUID.generate()}/processes/history"),
             404
           )

    assert json_response(get_as(ctx.act, "/machines/#{ctx.machine.id}/processes"), 403)
    assert json_response(get_as(ctx.act, "/machines/#{ctx.machine.id}/processes/history"), 403)
    assert json_response(build_conn() |> get("/api/v1/machines/#{ctx.machine.id}/processes"), 401)
  end

  test "history answers the stored top lists in time order, within 24 hours", ctx do
    now = DateTime.utc_now()
    feed(ctx.key, items(), DateTime.add(now, -7200))
    feed(ctx.key, items(), DateTime.add(now, -1800))
    feed(ctx.key, items(), DateTime.add(now, -600))
    path = "/machines/#{ctx.machine.id}/processes/history"

    hour = json_response(get_as(ctx.read, path), 200)
    assert %{"kind" => "memory", "samples" => [a, b]} = hour
    assert a["at"] < b["at"]
    assert Enum.map(a["items"], & &1["pid"]) == [1, 2, 3]

    cpu = json_response(get_as(ctx.read, path <> "?kind=cpu"), 200)
    assert Enum.map(hd(cpu["samples"])["items"], & &1["pid"]) == [2, 1, 3]

    from = DateTime.to_iso8601(DateTime.add(now, -86_400 * 3))

    assert %{"samples" => [_, _, _]} =
             json_response(get_as(ctx.read, path <> "?from=" <> URI.encode_www_form(from)), 200)

    assert json_response(get_as(ctx.read, path <> "?kind=disk"), 422)
    assert json_response(get_as(ctx.read, path <> "?from=yesterday"), 422)
  end

  test "an issue answers its snapshot as processes", ctx do
    service =
      Repo.insert!(%Service{machine_id: ctx.machine.id, slug: "machine", name: "The machine"})

    feed(ctx.key, items())

    check =
      Repo.insert!(%Dokkit.Check{
        service_id: service.id,
        name: "w",
        type: :"windows-service",
        fail_after: 1
      })

    Dokkit.Issues.record(check, :down)
    issue = Repo.one!(Issue)
    body = json_response(get_as(ctx.read, "/issues/#{issue.id}"), 200)
    assert %{"processes" => %{"top_memory" => [%{"pid" => 1} | _], "top_cpu" => _}} = body

    other =
      Repo.insert!(%Dokkit.Check{service_id: service.id, name: "h", type: :http, fail_after: 1})

    Dokkit.Issues.record(other, :down)
    plain = Repo.get_by!(Issue, check_id: other.id)
    refute Map.has_key?(json_response(get_as(ctx.read, "/issues/#{plain.id}"), 200), "processes")
  end

  describe "the MCP" do
    defp tool(token, name, args) do
      body = %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: args}
      }

      result =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)
        |> json_response(200)
        |> Map.fetch!("result")

      {result["isError"] == true, result["content"] |> List.last() |> Map.fetch!("text")}
    end

    test "processes and process_history answer by machine name or id", ctx do
      feed(ctx.key, items())

      {false, text} = tool(ctx.read, "processes", %{machine: "sql1", sort: "cpu", limit: 2})
      assert %{"count" => 3, "items" => [%{"pid" => 2}, %{"pid" => 1}]} = Jason.decode!(text)

      {false, text} = tool(ctx.read, "processes", %{machine: ctx.machine.id, pid: 3})
      assert %{"items" => [%{"pid" => 3}]} = Jason.decode!(text)

      {false, text} = tool(ctx.read, "process_history", %{machine: "sql1", kind: "cpu"})

      assert %{"kind" => "cpu", "samples" => [%{"items" => [%{"pid" => 2} | _]}]} =
               Jason.decode!(text)

      assert {true, "No such thing."} = tool(ctx.read, "processes", %{machine: "nowhere"})
      assert {true, "No such thing."} = tool(ctx.read, "process_history", %{machine: "nowhere"})
      assert {true, _} = tool(ctx.read, "process_history", %{machine: "sql1", kind: "disk"})
    end
  end
end
