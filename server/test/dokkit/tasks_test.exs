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

  defp declare(key, command, pin \\ "pin-1") do
    task = %{id: "restart", run: command, file: "/srv/portal/dokkit.toml"}
    task = if pin, do: Map.put(task, :pin, pin), else: task
    doc = %{schema: 1, service: %{id: "portal"}, task: [task]}
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
    assert Tasks.decide(task.id, "rm -rf /", task.pin, :accepted) == :error

    html =
      view
      |> element(~s(#task-#{task.id} button[phx-click="accepted"][phx-value-system="false"]))
      |> render_click()

    assert html =~ "No task is waiting"

    {:ok, view, html} = live(conn, "/tasks")
    assert html =~ "Never"
    html = view |> element("button", "Run") |> render_click()
    assert html =~ "Waiting for the machine"

    work = json_response(get(as(key), "/api/v1/work?wait=0"), 200)
    assert work["task"] == "restart"
    assert work["command_sha256"] == "pin-1"
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

    send(view.pid, {:settled, :page})
    html = render(view)
    assert html =~ "Finished"
    assert html =~ "Started portal"

    # A changed command is not runnable until it is accepted again.
    declare(key, "systemctl restart portal --now")
    assert Tasks.run(task.id, "sam") == nil
    assert [%{accepted: "systemctl restart portal"}] = Tasks.waiting()
    {:ok, _, html} = live(conn, "/found")
    assert html =~ "The command, its file or its script changed since it was accepted"
  end

  test "a changed pin puts an accepted task back to proposed and no work is handed out", %{
    key: key
  } do
    declare(key, "backup.bat", "pin-a")
    [task] = Tasks.waiting()
    :ok = Tasks.decide(task.id, "backup.bat", "pin-a", :accepted)
    assert Tasks.waiting() == []
    assert Tasks.run(task.id, "sam")

    declare(key, "backup.bat", "pin-b")
    assert [%{id: id}] = Tasks.waiting()
    assert id == task.id
    assert response(get(as(key), "/api/v1/work?wait=0"), 204)
    assert Tasks.run(task.id, "sam") == nil

    assert %{"items" => [%{"command_sha256" => "pin-a"}]} =
             json_response(get(as(key), "/api/v1/tasks/accepted"), 200)

    # What was shown is what is accepted: a pin that moved since is not.
    assert Tasks.decide(task.id, "backup.bat", "pin-a", :accepted) == :error
    :ok = Tasks.decide(task.id, "backup.bat", "pin-b", :accepted)
    assert Tasks.waiting() == []
    assert Tasks.run(task.id, "sam")
  end

  test "a dismissal holds only for the pin that was dismissed", %{key: key} do
    declare(key, "dismiss-me.bat", "pin-d1")
    [task] = Tasks.waiting()
    :ok = Tasks.decide(task.id, "dismiss-me.bat", "pin-d1", :dismissed)
    assert Tasks.waiting() == []
    declare(key, "dismiss-me.bat", "pin-d2")
    assert [%{id: id}] = Tasks.waiting()
    assert id == task.id
  end

  test "a task with no pin waits for a newer dokkit and never runs", %{conn: conn, key: key} do
    declare(key, "old.bat", nil)
    Repo.update_all(Dokkit.Task, set: [accepted: "old.bat"])
    assert [task] = Tasks.waiting()
    assert Tasks.decide(task.id, "old.bat", "", :accepted) == :error
    assert Tasks.run(task.id, "sam") == nil
    assert response(get(as(key), "/api/v1/work?wait=0"), 204)
    assert %{"items" => []} = json_response(get(as(key), "/api/v1/tasks/accepted"), 200)
    {:ok, _, html} = live(signed_in(conn), "/found")
    assert html =~ "Needs a newer dokkit on this machine"
  end

  test "a user token with act can run a task, and one without cannot", %{key: key} do
    declare(key, "true")
    [task] = Tasks.waiting()
    assert %{"items" => []} = json_response(get(as(key), "/api/v1/tasks/accepted"), 200)
    :ok = Tasks.decide(task.id, "true", task.pin, :accepted)

    assert %{"items" => [%{"task" => "restart", "command_sha256" => sha}]} =
             json_response(get(as(key), "/api/v1/tasks/accepted"), 200)

    assert sha == "pin-1"
    {read, _} = Keys.mint(:user, %{scopes: ["read"]})
    {act, _} = Keys.mint(:user, %{scopes: ["read", "act"]})

    assert %{"items" => [%{"name" => "restart", "last_run" => nil}]} =
             json_response(get(as(read), "/api/v1/tasks"), 200)

    assert json_response(post(as(read), "/api/v1/tasks/#{task.id}/run"), 403)
    assert %{"run" => run} = json_response(post(as(act), "/api/v1/tasks/#{task.id}/run"), 200)

    assert %{"items" => [%{"id" => ^run, "state" => "queued"}]} =
             json_response(get(as(read), "/api/v1/task-runs"), 200)
  end

  @tag :tmp_dir
  test "a task is ordinary unless accepted as the system account, and an update is only fetched",
       %{
         conn: conn,
         key: key,
         tmp_dir: dir
       } do
    declare(key, "true")
    [task] = Tasks.waiting()
    :ok = Tasks.decide(task.id, "true", task.pin, :accepted)
    run = Tasks.run(task.id, "sam")
    assert run

    assert %{"run" => id, "as" => "ordinary"} =
             json_response(get(as(key), "/api/v1/work?wait=0"), 200)

    assert id == run.id

    :ok = Tasks.decide(task.id, "true", task.pin, :accepted, true)
    Tasks.run(task.id, "sam")
    assert %{"as" => "system"} = json_response(get(as(key), "/api/v1/work?wait=0"), 200)

    # A file cannot take one of Dokkit's own names.
    put(as(key), "/api/v1/declare", %{
      schema: 1,
      service: %{id: "portal", name: "Upload portal"},
      task: [%{id: "dokkit:update", run: "format c:"}]
    })

    assert Tasks.waiting() == []

    machine = Dokkit.Repo.get_by!(Dokkit.Machine, name: "vault")
    assert Tasks.update(machine.id, "sam") == nil
    assert json_response(get(as(key), "/api/v1/program/windows-amd64"), 404)

    Application.put_env(:dokkit, :programs, dir)
    on_exit(fn -> Application.delete_env(:dokkit, :programs) end)
    File.write!(Path.join(dir, "version.txt"), "0.2.0\n")
    File.write!(Path.join(dir, "dokkit-windows-amd64.exe"), "the newer copy")
    assert json_response(get(as(key), "/api/v1/program/..%2Fversion.txt"), 404)
    assert response(get(as(key), "/api/v1/program/windows-amd64"), 200) == "the newer copy"

    Dokkit.Repo.update_all(Dokkit.Machine, set: [kind: :enrolled, program_version: "0.1.0"])
    {:ok, view, html} = live(signed_in(conn), "/versions")
    assert html =~ "This server holds 0.2.0"

    assert {:error, {:live_redirect, %{to: "/tasks"}}} =
             render_click(view, "fetch", %{"machine" => machine.id})

    assert %{"task" => "dokkit:update"} = json_response(get(as(key), "/api/v1/work?wait=0"), 200)
  end

  test "runs whose result never came, or that nobody took, are ended" do
    m = Repo.insert!(%Machine{name: "stale-sweep-box", kind: :enrolled})
    t = Repo.insert!(%Dokkit.Task{machine_id: m.id, name: "t", command: "c", accepted: "c"})
    old = DateTime.add(DateTime.utc_now(), -2, :day)

    stuck =
      Repo.insert!(%Dokkit.TaskRun{
        task_id: t.id,
        state: :running,
        started_at: old,
        output: "kept"
      })

    waiting = Repo.insert!(%Dokkit.TaskRun{task_id: t.id, state: :queued, inserted_at: old})
    fresh = Repo.insert!(%Dokkit.TaskRun{task_id: t.id, state: :queued})

    assert Tasks.expire() == 2
    assert Repo.reload!(stuck).state == :fail
    assert Repo.reload!(stuck).output == "kept\nNo result arrived from the machine."
    assert Repo.reload!(waiting).state == :refused
    assert Repo.reload!(fresh).state == :queued
  end
end
