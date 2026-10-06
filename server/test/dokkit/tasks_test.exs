defmodule Dokkit.TasksTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Dokkit.{Keys, Machine, Repo, Tasks}

  setup do
    machine = Repo.insert!(%Machine{name: "vault", kind: :enrolled})
    {key, _} = Keys.mint(:machine, %{machine_id: machine.id})
    %{key: key}
  end

  defp as(key), do: put_req_header(build_conn(), "authorization", "Bearer " <> key)

  defp declare(key, command) do
    doc = %{schema: 1, service: %{id: "portal"}, task: [%{id: "restart", run: command}]}
    assert json_response(put(as(key), "/api/v1/declare", doc), 200)
  end

  test "a task is offered, accepted, run by its machine, and offered again when it changes", %{
    conn: conn,
    key: key
  } do
    declare(key, "systemctl restart portal")
    conn = signed_in(conn)

    {:ok, view, html} = live(conn, "/found")
    assert html =~ "Found, waiting for you"
    assert html =~ "systemctl restart portal"
    assert html =~ ~s(aria-label="Found, 1")
    assert response(get(as(key), "/api/v1/work?wait=0"), 204)

    # The command the person saw is the one that is accepted.
    [task] = Tasks.waiting()
    assert Tasks.decide(task.id, "rm -rf /", :accepted) == :error
    html = view |> element("#task-#{task.id} button", "Accept") |> render_click()
    assert html =~ "No task is waiting"

    {:ok, view, html} = live(conn, "/tasks")
    assert html =~ "Never"
    html = view |> element("button", "Run") |> render_click()
    assert html =~ "Waiting for the machine"

    work = json_response(get(as(key), "/api/v1/work?wait=0"), 200)
    assert work["task"] == "restart"
    assert work["command_sha256"] == Tasks.sha256("systemctl restart portal")
    assert response(get(as(key), "/api/v1/work?wait=0"), 204)

    out = as(key) |> put_req_header("content-type", "text/plain")
    assert json_response(post(out, "/api/v1/work/#{work["run"]}/output", "Started portal\n"), 200)

    assert json_response(
             post(as(key), "/api/v1/work/#{work["run"]}/result", %{exit_code: 0, duration_ms: 900}),
             200
           )

    assert json_response(
             post(as(key), "/api/v1/work/#{work["run"]}/result", %{exit_code: 0}),
             404
           )

    html = render(view)
    assert html =~ "Finished"
    assert html =~ "Started portal"

    # A changed command is not runnable until it is accepted again.
    declare(key, "systemctl restart portal --now")
    assert Tasks.run(task.id, "sam") == nil
    assert [%{accepted: "systemctl restart portal"}] = Tasks.waiting()
    {:ok, _, html} = live(conn, "/found")
    assert html =~ "The command changed since it was accepted"
  end

  test "a user token with act can run a task, and one without cannot", %{key: key} do
    declare(key, "true")
    [task] = Tasks.waiting()
    assert %{"items" => []} = json_response(get(as(key), "/api/v1/tasks/accepted"), 200)
    :ok = Tasks.decide(task.id, "true", :accepted)

    assert %{"items" => [%{"task" => "restart", "command_sha256" => sha}]} =
             json_response(get(as(key), "/api/v1/tasks/accepted"), 200)

    assert sha == Tasks.sha256("true")
    {read, _} = Keys.mint(:user, %{scopes: ["read"]})
    {act, _} = Keys.mint(:user, %{scopes: ["read", "act"]})

    assert %{"items" => [%{"name" => "restart", "last_run" => nil}]} =
             json_response(get(as(read), "/api/v1/tasks"), 200)

    assert json_response(post(as(read), "/api/v1/tasks/#{task.id}/run"), 403)
    assert %{"run" => run} = json_response(post(as(act), "/api/v1/tasks/#{task.id}/run"), 200)

    assert %{"items" => [%{"id" => ^run, "state" => "queued"}]} =
             json_response(get(as(read), "/api/v1/task-runs"), 200)
  end
end
